/**
 * Tests for the book-level agent action.
 *
 * The action is a thin wrapper over CaseManagerAIDigestService, which has its
 * own suite — so these cover what the wrapper adds rather than re-testing the
 * triage: that the whole book comes back, that an empty book is reported as a
 * fact rather than a failure, and that a batched invocation is answered once
 * rather than N times.
 */
@IsTest
private class CaseManagerAIBookActionTest {
  private static Account makeAccount(String name) {
    Account a = new Account(Name = name, Stage__c = 'Signed');
    insert a;
    return a;
  }

  private static Opportunity makeOpp(Account a, String name) {
    return new Opportunity(
      Name = name,
      AccountId = a.Id,
      // Must be a CLOSED stage: loadBook() filters on IsClosed since
      // 2026-08-27, and 'Signed' is not a closed stage in any org here,
      // so a fixture using it produces an empty book and every
      // assertion below it fails for the wrong reason.
      StageName = 'Enrolled',
      CloseDate = Date.today().addDays(30),
      Case_Manager__c = UserInfo.getUserId()
    );
  }

  /**
   * The point of the action: a book-level answer with no case id supplied.
   *
   * Asserts on BOTH flagged cases, because a wrapper that returned only the
   * first would still pass a "briefing is not blank" check.
   */
  @IsTest
  static void returnsTheWholeBookRankedNotOneCase() {
    Account a = makeAccount('Book Client');
    Opportunity red = makeOpp(a, 'Red Case');
    red.UCC_Risk__c = 'High';
    Opportunity amber = makeOpp(a, 'Amber Case');
    amber.UCC_Risk__c = 'Medium';
    insert new List<Opportunity>{ red, amber };

    CaseManagerAIDigestService.recencyOverride = Date.today();

    Test.startTest();
    List<CaseManagerAIBookAction.Response> out = CaseManagerAIBookAction.getBookTriage(
      new List<CaseManagerAIBookAction.Request>{
        new CaseManagerAIBookAction.Request()
      }
    );
    Test.stopTest();

    System.assertEquals(1, out.size(), 'One request, one response.');
    System.assertEquals(true, out[0].success, 'Expected a successful triage.');
    System.assertEquals(
      null,
      out[0].errorMessage,
      'A successful triage must not carry an error message.'
    );
    System.assert(
      out[0].briefing.contains('Red Case'),
      'The red case is missing from the triage: ' + out[0].briefing
    );
    System.assert(
      out[0].briefing.contains('Amber Case'),
      'The amber case is missing — the action returned less than the whole book: ' +
        out[0].briefing
    );
    System.assert(
      out[0].briefing.contains('CASES IN BOOK'),
      'Expected the book header, got: ' + out[0].briefing
    );
  }

  /**
   * An empty book is an answer, not an error.
   *
   * If this returned success=false the agent would say the triage was
   * unavailable, when the truth is that the manager has nothing assigned.
   */
  @IsTest
  static void emptyBookIsReportedAsSuccess() {
    Test.startTest();
    List<CaseManagerAIBookAction.Response> out = CaseManagerAIBookAction.getBookTriage(
      new List<CaseManagerAIBookAction.Request>{
        new CaseManagerAIBookAction.Request()
      }
    );
    Test.stopTest();

    System.assertEquals(true, out[0].success, 'An empty book is not a failure.');
    System.assert(
      String.isNotBlank(out[0].briefing),
      'An empty book still needs a sentence the agent can read.'
    );
  }

  /**
   * A batched invocation must be answered per request, but evaluated once.
   *
   * Recomputing per request would multiply the triage's ~10 queries by the
   * batch size. Identical text across the responses is what shows the single
   * evaluation was reused.
   */
  @IsTest
  static void batchedRequestsAreAnsweredOnceAndCopied() {
    Account a = makeAccount('Batch Client');
    Opportunity o = makeOpp(a, 'Batch Case');
    o.UCC_Risk__c = 'High';
    insert o;

    CaseManagerAIDigestService.recencyOverride = Date.today();

    Test.startTest();
    List<CaseManagerAIBookAction.Response> out = CaseManagerAIBookAction.getBookTriage(
      new List<CaseManagerAIBookAction.Request>{
        new CaseManagerAIBookAction.Request(),
        new CaseManagerAIBookAction.Request(),
        new CaseManagerAIBookAction.Request()
      }
    );
    Integer queriesUsed = Limits.getQueries();
    Test.stopTest();

    System.assertEquals(3, out.size(), 'One response per request is required.');
    System.assertEquals(
      out[0].briefing,
      out[2].briefing,
      'Every response in one invocation describes the same book.'
    );
    System.assert(
      queriesUsed < 50,
      'Three requests should not have triaged the book three times. Queries: ' +
        queriesUsed
    );
  }

  /** An empty invocation is a no-op, not a null-pointer. */
  @IsTest
  static void emptyInvocationReturnsNothing() {
    System.assertEquals(
      0,
      CaseManagerAIBookAction.getBookTriage(
          new List<CaseManagerAIBookAction.Request>()
        )
        .size(),
      'No requests means no responses.'
    );
    System.assertEquals(
      0,
      CaseManagerAIBookAction.getBookTriage(null).size(),
      'A null request list must not throw.'
    );
  }

  /**
   * Truncation must announce itself.
   *
   * An agent handed a silently cut-off list would state a flagged count it
   * cannot enumerate.
   */
  @IsTest
  static void oversizedTriageIsClippedAndMarked() {
    String huge = 'x'.repeat(30000);

    Test.startTest();
    String clipped = CaseManagerAIBookAction.clip(huge);
    Test.stopTest();

    System.assert(
      clipped.length() <= 24000,
      'Clipped text still exceeds the budget: ' + clipped.length()
    );
    System.assert(
      clipped.contains('truncated'),
      'Truncation must be announced in the text the agent reads.'
    );
    System.assertEquals('', CaseManagerAIBookAction.clip(null), 'Null is safe.');
    System.assertEquals(
      'short',
      CaseManagerAIBookAction.clip('short'),
      'Text inside the budget must pass through untouched.'
    );
  }

  /**
   * The severity filter must return that band and nothing else.
   *
   * Asserting the amber case is ABSENT is the half that matters — a filter that
   * quietly returned everything would still pass a "contains the red case" check.
   */
  @IsTest
  static void severityFilterReturnsOnlyThatBand() {
    Account a = makeAccount('Filter Client');
    Opportunity red = makeOpp(a, 'Red Case');
    red.UCC_Risk__c = 'High';
    Opportunity amber = makeOpp(a, 'Amber Case');
    amber.UCC_Risk__c = 'Medium';
    insert new List<Opportunity>{ red, amber };

    CaseManagerAIBookAction.Request req = new CaseManagerAIBookAction.Request();
    req.severity = 'Red';

    CaseManagerAIDigestService.recencyOverride = Date.today();

    Test.startTest();
    List<CaseManagerAIBookAction.Response> out = CaseManagerAIBookAction.getBookTriage(
      new List<CaseManagerAIBookAction.Request>{ req }
    );
    Test.stopTest();

    System.assertEquals(true, out[0].success, 'Filtering is not a failure.');
    System.assert(
      out[0].briefing.contains('Red Case'),
      'The red case should be in a Red-filtered triage: ' + out[0].briefing
    );
    System.assert(
      !out[0].briefing.contains('Amber Case'),
      'An amber case leaked into a Red-filtered triage: ' + out[0].briefing
    );
    System.assert(
      out[0].briefing.contains('FLAGGED AT RED: 1'),
      'Expected the filtered count header, got: ' + out[0].briefing
    );
    System.assert(
      out[0].briefing.contains('CASES IN BOOK: 2'),
      'The book size must still be stated when filtered: ' + out[0].briefing
    );
  }

  /**
   * A filter that matches nothing must say so plainly.
   *
   * Returning an empty list would let the agent imply the book is clear when it
   * is only clear at that one severity.
   */
  @IsTest
  static void severityFilterWithNoMatchesSaysSo() {
    Account a = makeAccount('No Match Client');
    Opportunity red = makeOpp(a, 'Only Red Case');
    red.UCC_Risk__c = 'High';
    insert red;

    CaseManagerAIBookAction.Request req = new CaseManagerAIBookAction.Request();
    req.severity = 'Amber';

    CaseManagerAIDigestService.recencyOverride = Date.today();

    Test.startTest();
    List<CaseManagerAIBookAction.Response> out = CaseManagerAIBookAction.getBookTriage(
      new List<CaseManagerAIBookAction.Request>{ req }
    );
    Test.stopTest();

    System.assertEquals(true, out[0].success, 'No matches is not a failure.');
    System.assert(
      out[0].briefing.contains('FLAGGED AT AMBER: 0'),
      'Expected a zero count, got: ' + out[0].briefing
    );
    System.assert(
      out[0].briefing.contains('No case in this book is flagged at that severity'),
      'The agent needs an explicit sentence, got: ' + out[0].briefing
    );
    System.assert(
      !out[0].briefing.contains('Only Red Case'),
      'A red case leaked into an Amber-filtered triage: ' + out[0].briefing
    );
  }

  /**
   * Mixed filters in one invocation are answered independently, still off a
   * single evaluation of the book.
   */
  @IsTest
  static void mixedFiltersInOneInvocationAreAnsweredIndependently() {
    Account a = makeAccount('Mixed Client');
    Opportunity red = makeOpp(a, 'Red Case');
    red.UCC_Risk__c = 'High';
    Opportunity amber = makeOpp(a, 'Amber Case');
    amber.UCC_Risk__c = 'Medium';
    insert new List<Opportunity>{ red, amber };

    CaseManagerAIBookAction.Request redReq = new CaseManagerAIBookAction.Request();
    redReq.severity = 'Red';
    CaseManagerAIBookAction.Request allReq = new CaseManagerAIBookAction.Request();

    CaseManagerAIDigestService.recencyOverride = Date.today();

    Test.startTest();
    List<CaseManagerAIBookAction.Response> out = CaseManagerAIBookAction.getBookTriage(
      new List<CaseManagerAIBookAction.Request>{ redReq, allReq }
    );
    Test.stopTest();

    System.assertEquals(2, out.size(), 'One response per request.');
    System.assert(
      !out[0].briefing.contains('Amber Case'),
      'The filtered response should exclude amber: ' + out[0].briefing
    );
    System.assert(
      out[1].briefing.contains('Amber Case'),
      'The unfiltered response should include amber: ' + out[1].briefing
    );
  }

  /**
   * A transaction that has already spent its query budget gets an honest
   * refusal, not a LimitException.
   *
   * Queries are burned AFTER Test.startTest(), because startTest resets the
   * governor counters — burning them before would prove nothing. 80 used of 100
   * leaves less than the 25 the guard requires, so it trips.
   */
  @IsTest
  static void exhaustedQueryBudgetIsRefusedHonestly() {
    Account a = makeAccount('Budget Client');
    Opportunity o = makeOpp(a, 'Budget Case');
    o.UCC_Risk__c = 'High';
    insert o;

    CaseManagerAIDigestService.recencyOverride = Date.today();

    Test.startTest();
    for (Integer i = 0; i < 80; i++) {
      List<Account> ignored = [SELECT Id FROM Account LIMIT 1];
    }
    List<CaseManagerAIBookAction.Response> out = CaseManagerAIBookAction.getBookTriage(
      new List<CaseManagerAIBookAction.Request>{
        new CaseManagerAIBookAction.Request(),
        new CaseManagerAIBookAction.Request()
      }
    );
    Test.stopTest();

    System.assertEquals(2, out.size(), 'Every request still gets an answer.');
    System.assertEquals(
      false,
      out[0].success,
      'A refusal must be reported as unsuccessful.'
    );
    System.assert(
      out[0].errorMessage.contains('Query budget exhausted'),
      'The detail belongs in errorMessage, got: ' + out[0].errorMessage
    );
    System.assert(
      out[0].briefing.contains('read too much data'),
      'The agent needs a sentence it can say out loud, got: ' + out[0].briefing
    );
    System.assertEquals(
      out[0].briefing,
      out[1].briefing,
      'The refusal is copied to every request in the invocation.'
    );
  }
}
