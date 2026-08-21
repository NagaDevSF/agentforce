/**
 * @AuraEnabled surface for the caseManagerAI Lightning Web Component.
 *
 * This class is deliberately thin: it validates, delegates to
 * CaseManagerAIService and converts exceptions into AuraHandledException so the
 * LWC gets a readable message instead of "An internal server error occurred".
 *
 * SHARING: `with sharing` all the way down. This controller, CaseManagerAIService
 * and CaseManagerAIDigestService are all now `with sharing`, matching
 * csCaseManagerDashboardController — so there is no elevation anywhere on this
 * path and nothing left to keep narrow. Record access is the platform's decision;
 * the Case_Manager__c filter in the service scopes on top of it.
 *
 * STORES NOTHING. The stored-brief object and every method that read or wrote it
 * were removed on 2026-08-18 - this feature keeps no data of its own, and there
 * is no longer an org-wide-default question to get wrong. getMorningDigest()
 * still returns the morning triage, but it is computed live from the Opportunity
 * book on each call rather than persisted. The trade that buys: the digest is
 * recomputed per request instead of once per manager per day.
 */
public with sharing class CaseManagerAIController {
  /**
   * The running user's caseload. No user-id parameter by design — see the class
   * comment on CaseManagerAIService.
   */
  @AuraEnabled(cacheable=true)
  public static List<CaseManagerAIService.CaseTile> getMyCases(
    String searchTerm,
    Integer maxRows
  ) {
    try {
      return CaseManagerAIService.getMyCases(searchTerm, maxRows);
    } catch (Exception e) {
      throw toAuraException(e);
    }
  }

  /**
   * The full 360° briefing for one case. Not cacheable: case managers refresh
   * this after acting on the record and must see current data.
   */
  @AuraEnabled
  public static CaseManagerAIService.CaseContext getCaseContext(
    Id opportunityId
  ) {
    try {
      return CaseManagerAIService.getCaseContext(opportunityId);
    } catch (Exception e) {
      throw toAuraException(e);
    }
  }

  /**
   * Resolves whichever record the component is sitting on to the Opportunity it
   * should summarise, so the same component works on an Opportunity page and on
   * an Account page.
   *
   * On an Account, this returns the running user's most recent case for that
   * account — a case manager who does not own any of the account's cases gets
   * null, and the component renders its "no access" state.
   */
  @AuraEnabled(cacheable=true)
  public static Id resolveOpportunityId(Id recordId) {
    if (recordId == null) {
      return null;
    }
    try {
      String prefix = String.valueOf(recordId).substring(0, 3);
      String oppPrefix = Opportunity.SObjectType.getDescribe()
        .getKeyPrefix();
      if (prefix == oppPrefix) {
        return recordId;
      }

      String accountPrefix = Account.SObjectType.getDescribe().getKeyPrefix();
      if (prefix == accountPrefix) {
        List<CaseManagerAIService.CaseTile> tiles = CaseManagerAIService.getMyCases(
          null,
          500
        );
        for (CaseManagerAIService.CaseTile t : tiles) {
          if (t.accountId == recordId) {
            return t.id;
          }
        }
      }
      return null;
    } catch (Exception e) {
      throw toAuraException(e);
    }
  }

  /** Tells the component whether to show the "viewing all cases" badge. */
  @AuraEnabled(cacheable=true)
  public static Boolean canViewAllCases() {
    return FeatureManagement.checkPermission('Case_Manager_AI_View_All') == true;
  }

  /**
   * The morning digest for the running user's whole book, for the alert banner
   * above the caseload list.
   *
   * Not cacheable: a case manager who clears a flag and refreshes must see the
   * banner change, and the digest is cheap — it is deterministic Apex, not a
   * generation. No user-id parameter, for the same reason as getMyCases().
   */
  @AuraEnabled
  public static CaseManagerAIDigestService.MorningDigest getMorningDigest() {
    try {
      return CaseManagerAIDigestService.buildMorningDigest();
    } catch (Exception e) {
      throw toAuraException(e);
    }
  }


  private static AuraHandledException toAuraException(Exception e) {
    // setMessage is required: without it the LWC receives the generic platform
    // message rather than the text passed to the constructor.
    AuraHandledException ex = new AuraHandledException(e.getMessage());
    ex.setMessage(e.getMessage());
    return ex;
  }
}