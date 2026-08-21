/**
 * Agentforce Agent Action (and Flow invocable) that hands the agent a complete,
 * plain-text briefing on a case so it can answer questions about it.
 *
 * HOW THIS PLUGS INTO AGENTFORCE
 * ------------------------------
 * 1. Deploy this class.
 * 2. Setup → Agentforce Agents → open (or create) your agent → New Agent Action
 *    → Reference Action Type "Apex" → pick "Get Case Manager AI Briefing".
 * 3. Add the action to the agent's topic (e.g. "Case Management") and write the
 *    topic instructions to call it whenever the user asks about a case.
 *
 * The agent supplies the Opportunity id from context. It does NOT supply a user
 * id — the class always resolves the case manager from the session, so an agent
 * cannot be prompt-injected into reading another rep's book.
 *
 * SHARING — with sharing, matching csCaseManagerDashboard. The briefing is built
 * in the running user's sharing context, so an agent answering on behalf of a
 * case manager sees exactly what that manager may see and no more. Sections the
 * user has no record access to come back empty rather than elevated; see the
 * header on CaseManagerAIService for which ones that currently affects.
 *
 * SAFE FOR AN LLM: the briefing text is built by CaseManagerAIService.buildDigest,
 * which never selects bank routing numbers, account numbers, SSN or Plaid access
 * tokens. Anything that must not reach a model must not be added to that digest.
 *
 * NO CALLOUTS. This action only reads Salesforce data; the language model is
 * Agentforce's, so there is nothing to configure in Named Credentials.
 */
public with sharing class CaseManagerAIAgentAction {
  /**
   * SOQL a single getCaseContext call can consume, worst case.
   *
   * Measured by tracing every loader in CaseManagerAIService: ~25 for a case
   * with children in every section, ~15 for a sparse one. Used as a budget, not
   * a promise - if a loader is added there, raise this.
   */
  private static final Integer SOQL_PER_CASE = 26;

  /** Queries left in reserve for whatever else the transaction still has to do. */
  private static final Integer SOQL_HEADROOM = 10;

  /**
   * Aggregate character budget for one briefing.
   *
   * The per-collection caps in CaseManagerAIService bound each section, not the
   * total: 50 notes at 1,500 characters is 75,000 from notes alone. The agent
   * has to fit this alongside its own instructions and the conversation so far,
   * so the whole briefing is capped rather than each part of it.
   */
  private static final Integer BRIEFING_MAX_CHARS = 24000;

  private static final String TRUNCATION_NOTICE =
    '\n\n[Briefing truncated to fit. Ask about a specific section - payments, ' +
    'settlements, creditors, docusign, banking, activity, contacts, cases or ' +
    'notes - for the full detail.]';

  /**
   * What the planner is told when a case cannot be read.
   *
   * Deliberately fixed text. The underlying exception may name a field, an
   * object or a governor limit, and whatever goes in here is content the agent
   * reads back to a user; the detail belongs in errorMessage, which is for logs.
   */
  private static final String UNAVAILABLE_BRIEFING =
    'No briefing is available for this case. It may not be assigned to you.';

  public class Request {
    @InvocableVariable(
      required=true
      label='Case (Opportunity) Id'
      description='The Salesforce Id of the Opportunity that represents the client case to summarise.'
    )
    public Id opportunityId;

    @InvocableVariable(
      label='Sections'
      description='Optional comma-separated list to narrow the briefing: payments, settlements, creditors, docusign, banking, activity, contacts, cases, notes. Leave blank for the full picture.'
    )
    public String sections;
  }

  public class Response {
    @InvocableVariable(
      label='Briefing'
      description='Plain-text 360 briefing covering the case, its payment plan and schedule, creditors and settlement plans, DocuSign envelopes, banking and Plaid data, contacts and recent activity.'
    )
    public String briefing;

    @InvocableVariable(
      label='Success'
      description='False when the case could not be read — check Error Message.'
    )
    public Boolean success;

    @InvocableVariable(
      label='Error Message'
      description='Why the briefing could not be produced. Blank on success.'
    )
    public String errorMessage;
  }

  /**
   * Bulk-safe: Agentforce sends one request per turn, but Flow may batch.
   *
   * One case costs up to SOQL_PER_CASE queries, so cost scales with input size
   * and the platform's 2,000-row invocable cap is far above what a single
   * transaction can serve. Rather than leave that to the caller, each request
   * checks the remaining query budget first and is refused with an explanation
   * if there is not enough left — a short honest answer for four cases beats a
   * LimitException for the last forty.
   */
  @InvocableMethod(
    label='Get Case Manager AI Briefing'
    description='Returns a complete plain-text briefing for a client case — payment plan and schedule items, creditors, settlement plans/segments/items, DocuSign envelopes, Plaid and Bank Connect verification, contacts, service cases and recent activity. Only returns cases where the running user is the Case Manager.'
    category='Case Manager AI'
  )
  public static List<Response> getBriefing(List<Request> requests) {
    List<Response> responses = new List<Response>();

    for (Request req : requests) {
      Response res = new Response();

      // Stop before the governor does. Without this, a Flow batching five rows
      // exhausts the 100-query limit partway through the fourth and every
      // remaining request fails with an opaque LimitException — most of the
      // batch silently degraded rather than one request honestly refused.
      if (!hasQueryBudget()) {
        res.success = false;
        res.errorMessage =
          'Query budget exhausted: ' +
          Limits.getQueries() +
          ' of ' +
          Limits.getLimitQueries() +
          ' SOQL used before this request.';
        res.briefing =
          'This request covered too many cases to brief in one transaction. ' +
          'Ask about one case at a time.';
        responses.add(res);
        continue;
      }

      try {
        CaseManagerAIService.CaseContext ctx = CaseManagerAIService.getCaseContext(
          req.opportunityId
        );
        res.briefing = clipBriefing(
          applySectionFilter(ctx.digest, req.sections)
        );
        res.success = true;
      } catch (Exception e) {
        // Never let one bad row abort the whole invocation — the agent needs a
        // usable answer for the cases it CAN read. The exception text stays in
        // errorMessage; briefing is what the agent says out loud.
        res.success = false;
        res.errorMessage = e.getTypeName() + ': ' + e.getMessage();
        res.briefing = UNAVAILABLE_BRIEFING;
      }
      responses.add(res);
    }
    return responses;
  }

  /** True while this transaction can still afford a full case briefing. */
  private static Boolean hasQueryBudget() {
    Integer left = Limits.getLimitQueries() - Limits.getQueries();
    return left >= SOQL_PER_CASE + SOQL_HEADROOM;
  }

  /**
   * Holds one briefing inside the aggregate budget.
   *
   * Truncation is announced rather than silent: an agent that receives a cut-off
   * briefing with no marker will answer confidently from the half it got, and
   * "no DocuSign envelopes on this case" is a very different statement from
   * "the DocuSign section did not fit".
   */
  @TestVisible
  private static String clipBriefing(String briefing) {
    if (String.isBlank(briefing) || briefing.length() <= BRIEFING_MAX_CHARS) {
      return briefing;
    }
    Integer keep = BRIEFING_MAX_CHARS - TRUNCATION_NOTICE.length();
    return briefing.substring(0, keep) + TRUNCATION_NOTICE;
  }

  /**
   * Trims the digest to the requested sections. The digest is built as
   * "--- SECTION NAME ---" blocks, so filtering is a matter of keeping the
   * header block plus the blocks the caller asked for.
   */
  @TestVisible
  private static String applySectionFilter(String digest, String sections) {
    if (String.isBlank(sections) || String.isBlank(digest)) {
      return digest;
    }

    Map<String, String> aliasToHeader = new Map<String, String>{
      'payments' => 'PAYMENT',
      'settlements' => 'SETTLEMENT',
      'creditors' => 'ENROLLED CREDITORS',
      'docusign' => 'DOCUSIGN',
      'banking' => 'BANKING',
      'activity' => 'RECENT ACTIVITY',
      'contacts' => 'CONTACTS',
      'cases' => 'SERVICE CASES',
      'notes' => 'NOTES'
    };

    Set<String> wanted = new Set<String>();
    for (String raw : sections.split(',')) {
      String key = raw.trim().toLowerCase();
      if (aliasToHeader.containsKey(key)) {
        wanted.add(aliasToHeader.get(key));
      }
    }
    if (wanted.isEmpty()) {
      return digest;
    }

    List<String> kept = new List<String>();
    Boolean keeping = true; // the leading header block is always kept

    for (String line : digest.split('\n')) {
      if (line.startsWith('--- ')) {
        keeping = false;
        for (String header : wanted) {
          if (line.contains(header)) {
            keeping = true;
            break;
          }
        }
      }
      if (keeping) {
        kept.add(line);
      }
    }
    return String.join(kept, '\n');
  }
}