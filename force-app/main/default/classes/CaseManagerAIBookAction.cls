/**
 * Agentforce Agent Action (and Flow invocable) that hands the agent the running
 * case manager's WHOLE BOOK, ranked — not one case.
 *
 * WHY THIS EXISTS ALONGSIDE CaseManagerAIAgentAction
 * --------------------------------------------------
 * The other action answers "what is going on with THIS case" and requires an
 * Opportunity id. It cannot answer "what needs my attention today", because
 * there is no single case to name. Without this class the planner has no action
 * for a book-level question and will either refuse or, worse, pick one case and
 * answer as though it were the whole picture.
 *
 * Both actions should be on the topic. Route on the question:
 *   - "my book", "today", "what needs attention", "anything urgent"  -> this one
 *   - "this case", a named client, a record in context                -> the other
 *
 * COST. This is CHEAPER than a single-case briefing, which is the opposite of
 * what the existing topic instruction ("one case per turn") implies. The whole
 * book is roughly ten queries because the triage reads aggregates, where one
 * full case briefing reads about twenty-six. That instruction needs rewording
 * when this action is added, or the agent will refuse the very question this
 * action exists to answer.
 *
 * IDENTITY IS NEVER AN INPUT. The only invocable variable is an optional
 * severity filter. The case manager is always UserInfo.getUserId(), resolved
 * inside CaseManagerAIDigestService. Adding a "case manager id" input would let
 * a prompt-injected agent read another rep's book, which is exactly the control
 * the rest of this feature is built around.
 *
 * NO LANGUAGE MODEL RUNS HERE. The triage is deterministic Apex over field
 * values; groundingText is assembled from those values and is documented as
 * safe for a model — names, statuses, counts and dates only. Agentforce's own
 * model phrases the reply. Nothing that must not reach a model may be added to
 * groundingText.
 *
 * NO CALLOUTS, NO DML. Reads only.
 */
public with sharing class CaseManagerAIBookAction {
  /**
   * SOQL one book triage can consume, worst case.
   *
   * The triage loads the book, active plans, NSF items, activity signals, notes
   * and open cases — roughly ten queries, aggregates rather than per-case rows.
   * Held as a budget, not a promise: if a loader is added to
   * CaseManagerAIDigestService, raise this.
   */
  private static final Integer SOQL_PER_BOOK = 15;

  /** Queries left in reserve for whatever else the transaction still has to do. */
  private static final Integer SOQL_HEADROOM = 10;

  /**
   * Aggregate character budget, matching the single-case action.
   *
   * A book of 500 cases with 287 flagged runs to tens of thousands of
   * characters — measured in production on 2026-08-19 — and the agent has to
   * fit this alongside its own instructions and the conversation so far.
   */
  private static final Integer BRIEFING_MAX_CHARS = 24000;

  private static final String TRUNCATION_NOTICE =
    '\n\n[Triage truncated to fit. The cases above are the most urgent — they ' +
    'are ranked, so nothing important was dropped from the top. Ask about one ' +
    'case by name for its full briefing.]';

  /**
   * What the planner is told when the book cannot be read.
   *
   * Deliberately fixed text, for the same reason as the single-case action: the
   * underlying exception may name a field, an object or a governor limit, and
   * this is content the agent reads back to a user. Detail goes to errorMessage.
   */
  private static final String UNAVAILABLE_TRIAGE =
    'No triage is available right now. Your cases may not be assigned to you, ' +
    'or the Case Manager AI permission set may not be assigned to your user.';

  /**
   * One optional input, and deliberately not an identity.
   *
   * An @InvocableMethod parameter class must expose at least one
   * @InvocableVariable — an empty one does not compile — so this action carries
   * the filter the agent genuinely needs rather than a placeholder. There is
   * still NO case manager id: that is always resolved from the session.
   */
  public class Request {
    @InvocableVariable(
      label='Severity'
      description='Optional. "Red" returns only the most urgent cases, "Amber" only the middle band. Leave blank for the whole book, which is the normal case.'
    )
    public String severity;
  }

  public class Response {
    @InvocableVariable(
      label='Briefing'
      description='The running case manager\'s whole book, ranked most urgent first: how many cases, how many flagged red and amber, and one line per flagged case naming what breached.'
    )
    public String briefing;

    @InvocableVariable(
      label='Success'
      description='False when the triage could not be built — check Error Message.'
    )
    public Boolean success;

    @InvocableVariable(
      label='Error Message'
      description='Why the triage could not be produced. Blank on success. Filter this from the agent action so it is never read aloud.'
    )
    public String errorMessage;
  }

  /**
   * Builds the book triage once and answers every request in the invocation
   * with it.
   *
   * The digest depends only on the running user, so N requests in one
   * transaction describe the same book. Computing it once is not just an
   * optimisation: recomputing per request would multiply ten queries by the
   * batch size and hit the governor limit on a batch the agent had every right
   * to send.
   */
  @InvocableMethod(
    label='Get Case Manager AI Book Triage'
    description='Returns the running case manager\'s entire caseload, triaged and ranked most urgent first — how many cases they hold, how many are flagged red and amber, and what breached on each flagged case. Use this for questions about the whole book ("what needs my attention today"), not about one named case. The only input is an optional severity filter; the case manager is always resolved from the session.'
    category='Case Manager AI'
  )
  public static List<Response> getBookTriage(List<Request> requests) {
    List<Response> responses = new List<Response>();
    if (requests == null || requests.isEmpty()) {
      return responses;
    }

    // Evaluated once; each request only re-reads the result through its own
    // filter. Recomputing per request would multiply ten queries by the batch
    // size and hit the governor limit on a batch the agent had every right to
    // send.
    Outcome outcome = buildOnce();
    for (Request req : requests) {
      responses.add(render(outcome, req == null ? null : req.severity));
    }
    return responses;
  }

  /** The single evaluation, before any per-request filtering. */
  private class Outcome {
    CaseManagerAIDigestService.MorningDigest digest;
    Response failure;
  }

  /**
   * Applies one request's filter to the shared evaluation.
   *
   * A blank severity — the normal case — returns groundingText untouched, which
   * is the text CaseManagerAIDigestService documents as safe for a model. A
   * filter rebuilds an equivalent, shorter list from the same alerts rather
   * than editing that string, because slicing prose by severity is guesswork.
   */
  private static Response render(Outcome outcome, String severity) {
    if (outcome.failure != null) {
      return copyOf(outcome.failure);
    }

    Response res = new Response();
    res.success = true;

    if (String.isBlank(severity)) {
      res.briefing = clip(outcome.digest.groundingText);
      return res;
    }

    String wanted = severity.trim().toLowerCase();
    List<String> lines = new List<String>();
    lines.add('CASE MANAGER: ' + outcome.digest.generatedForUser);
    lines.add('CASES IN BOOK: ' + outcome.digest.caseCount);

    List<String> rows = new List<String>();
    for (
      CaseManagerAIDigestService.CaseAlert a : outcome.digest.alerts
    ) {
      if (a.severity == null || a.severity.toLowerCase() != wanted) {
        continue;
      }
      rows.add(
        '- [' +
          a.severity.toUpperCase() +
          '] ' +
          a.opportunityName +
          ' (' +
          a.accountName +
          ') — ' +
          String.join(a.triggers, ' · ')
      );
    }

    lines.add(
      'FLAGGED AT ' + severity.trim().toUpperCase() + ': ' + rows.size()
    );
    if (rows.isEmpty()) {
      lines.add('No case in this book is flagged at that severity.');
    } else {
      lines.add('');
      lines.add('MOST URGENT FIRST:');
      lines.addAll(rows);
    }
    res.briefing = clip(String.join(lines, '\n'));
    return res;
  }

  /** The single real evaluation behind however many requests arrived. */
  private static Outcome buildOnce() {
    Outcome outcome = new Outcome();
    Response res = new Response();

    // Stop before the governor does. A Flow or agent turn that has already
    // spent its query budget gets an honest refusal rather than an opaque
    // LimitException partway through the loaders.
    Integer left = Limits.getLimitQueries() - Limits.getQueries();
    if (left < SOQL_PER_BOOK + SOQL_HEADROOM) {
      res.success = false;
      res.errorMessage =
        'Query budget exhausted: ' +
        Limits.getQueries() +
        ' of ' +
        Limits.getLimitQueries() +
        ' SOQL used before this request.';
      res.briefing =
        'This conversation has already read too much data to triage the book ' +
        'in the same turn. Ask again in a new message.';
      outcome.failure = res;
      return outcome;
    }

    try {
      outcome.digest = CaseManagerAIDigestService.buildMorningDigest();
    } catch (Exception e) {
      // The agent still needs something usable to say. Detail goes to
      // errorMessage, which the topic filters from the agent's output.
      res.success = false;
      res.errorMessage = e.getTypeName() + ': ' + e.getMessage();
      res.briefing = UNAVAILABLE_TRIAGE;
      outcome.failure = res;
    }
    return outcome;
  }

  private static Response copyOf(Response source) {
    Response res = new Response();
    res.briefing = source.briefing;
    res.success = source.success;
    res.errorMessage = source.errorMessage;
    return res;
  }

  /**
   * Holds the triage inside the character budget.
   *
   * Truncation is announced rather than silent. Unlike a case briefing, cutting
   * the tail here is comparatively safe — the cases are ranked, so what falls
   * off the end is the least urgent — but an agent handed a cut-off list with no
   * marker would state a flagged count it cannot actually enumerate.
   */
  @TestVisible
  private static String clip(String text) {
    if (String.isBlank(text)) {
      return '';
    }
    if (text.length() <= BRIEFING_MAX_CHARS) {
      return text;
    }
    Integer keep = BRIEFING_MAX_CHARS - TRUNCATION_NOTICE.length();
    return text.substring(0, keep) + TRUNCATION_NOTICE;
  }
}
