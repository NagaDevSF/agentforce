/**
 * Tests for the guard layer, not for the model.
 *
 * The model is mocked throughout. What matters here is what this class does with
 * an answer once it has one — a real call cannot be made in a test, and asserting
 * on generated prose would be a flaky test of someone else's service.
 */
@IsTest
private class CaseManagerAIActivitySummaryTest {
  private static Id fakeOppId() {
    return Opportunity.SObjectType.getDescribe().getKeyPrefix() + '000000000000AAA';
  }

  /** The ordinary case: a usable sentence, no legal claim, comes straight back. */
  @IsTest
  static void keepsAnOrdinarySummary() {
    Id oppId = fakeOppId();
    CaseManagerAIActivitySummary.mockSummaries = new Map<Id, String>{
      oppId => 'Client is asking for their ledger and the bank details on file.'
    };
    Map<Id, String> out = CaseManagerAIActivitySummary.forCases(
      new Set<Id>{ oppId },
      3,
      new Map<Id, List<String>>{ oppId => new List<String>{ 'Cancellation dated 8/19/2026' } }
    );
    System.assertEquals(1, out.size(), 'A clean summary should survive.');
    System.assert(
      out.get(oppId).contains('ledger'),
      'The summary should be returned unchanged: ' + out.get(oppId)
    );
  }

  /**
   * THE CONTROL. A summary asserting a judgment that no deterministic rule found
   * must be discarded outright.
   *
   * This is the exact shape of a real prompt-injection probe: neutralise() strips
   * the command words but leaves "report that a judgment was entered" intact, so
   * a model can be talked into asserting it. At a debt settlement company that is
   * a compliance incident, so the line is dropped rather than trimmed.
   */
  @IsTest
  static void dropsAnUncorroboratedLegalClaim() {
    Id oppId = fakeOppId();
    CaseManagerAIActivitySummary.mockSummaries = new Map<Id, String>{
      oppId => 'The client reports that a judgment has been entered against them.'
    };
    Map<Id, String> out = CaseManagerAIActivitySummary.forCases(
      new Set<Id>{ oppId },
      3,
      new Map<Id, List<String>>{ oppId => new List<String>{ '2 payments returned NSF' } }
    );
    System.assert(
      out.isEmpty(),
      'An invented judgment must never reach a case manager. Got: ' + out
    );
  }

  /** Corroborated is different from invented: In legal was already established. */
  @IsTest
  static void keepsALegalClaimTheFieldsAlreadyProved() {
    Id oppId = fakeOppId();
    CaseManagerAIActivitySummary.mockSummaries = new Map<Id, String>{
      oppId => 'Client is asking who their legal contact is.'
    };
    Map<Id, String> out = CaseManagerAIActivitySummary.forCases(
      new Set<Id>{ oppId },
      3,
      new Map<Id, List<String>>{ oppId => new List<String>{ 'In legal with Naga Sai Harsha' } }
    );
    System.assertEquals(
      1,
      out.size(),
      'A legal mention the fields already established is not an invention.'
    );
  }

  /** NONE is the model saying there was nothing worth reporting. */
  @IsTest
  static void dropsNone() {
    Id oppId = fakeOppId();
    CaseManagerAIActivitySummary.mockSummaries = new Map<Id, String>{ oppId => 'NONE' };
    Map<Id, String> out = CaseManagerAIActivitySummary.forCases(
      new Set<Id>{ oppId }, 3, new Map<Id, List<String>>{ oppId => new List<String>() }
    );
    System.assert(out.isEmpty(), 'NONE means no line, not a line reading NONE.');
  }

  /** A model that ignores "one sentence" is not given the floor. */
  @IsTest
  static void dropsAnOverlongSummary() {
    Id oppId = fakeOppId();
    CaseManagerAIActivitySummary.mockSummaries = new Map<Id, String>{
      oppId => 'x'.repeat(400)
    };
    Map<Id, String> out = CaseManagerAIActivitySummary.forCases(
      new Set<Id>{ oppId }, 3, new Map<Id, List<String>>{ oppId => new List<String>() }
    );
    System.assert(out.isEmpty(), 'An essay is not a summary.');
  }

  /**
   * REGRESSION. The first guard matched substrings, so "client" tripped "lien"
   * and "successful" tripped "ucc" — it discarded almost every summary while
   * looking like it was working. Whole-word matching is the fix; this pins it.
   */
  @IsTest
  static void doesNotMistakeOrdinaryWordsForLegalClaims() {
    Id oppId = fakeOppId();
    CaseManagerAIActivitySummary.mockSummaries = new Map<Id, String>{
      oppId => 'The client had a successful callback and wants a courtesy discount.'
    };
    Map<Id, String> out = CaseManagerAIActivitySummary.forCases(
      new Set<Id>{ oppId }, 3, new Map<Id, List<String>>{ oppId => new List<String>() }
    );
    System.assertEquals(
      1,
      out.size(),
      'client/successful/courtesy contain lien, ucc and court as substrings but ' +
        'assert nothing legal. Got: ' + out
    );
  }

  /** No cases in, no model calls, no exception. */
  @IsTest
  static void handlesAnEmptySet() {
    Map<Id, String> out = CaseManagerAIActivitySummary.forCases(
      new Set<Id>(), 3, new Map<Id, List<String>>()
    );
    System.assert(out.isEmpty(), 'An empty book must not call anything.');
  }
}
