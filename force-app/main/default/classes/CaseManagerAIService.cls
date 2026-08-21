/**
 * Aggregates a complete 360° picture of a client file (Opportunity) for the
 * Case Manager AI component and for the Agentforce agent action.
 *
 * SHARING MODEL — with sharing, with one narrow, documented exception
 * -------------------------------------------------------------------
 * This class runs in the running user's sharing context. Record-level access is
 * decided by the platform (org-wide defaults, sharing rules, role hierarchy),
 * exactly as it is in the Cs* case-manager dashboard controllers.
 *
 * THE EXCEPTION: payment and settlement rows are read through the private inner
 * class PaymentDataReader, which is `without sharing`. See the comment on that
 * class for the full reasoning; in short, production OWD is Private on
 * PaymentPlan__c and a case manager owns none of the plans on their own book, so
 * under strict sharing the Payments and Settlements sections were empty on every
 * case. Field-level security is still enforced there, by stripInaccessible()
 * rather than by USER_MODE, and the row scope is unchanged.
 *
 * BANK DATA IS NOT ELEVATED. Account_Bank_Information__c and
 * bankconnect__Bank_Verification__c stay in the running user's sharing context.
 * If the Banking section is empty for a user, that is the intended behaviour —
 * grant Read and share those records rather than widening the exception.
 *
 * THE EXPLICIT FILTER IS STILL LOAD-BEARING. Sharing is no longer the only
 * control, but it is not a substitute for scoping either: sharing decides what a
 * user *may* read, while Case_Manager__c decides what is *theirs*. Both rules
 * below still hold and must not be relaxed:
 *
 *   1. The case manager is ALWAYS UserInfo.getUserId(). This class never
 *      accepts a user id, case-manager id, or "view as" parameter from a
 *      caller. If it did, any authenticated user could pass Eli's id and read
 *      his entire caseload.
 *   2. Every public entry point that takes an Opportunity id runs it through
 *      assertCaseAccess() BEFORE querying anything else.
 *
 * Broader visibility (supervisors, admins, QA) needs BOTH the
 * Case_Manager_AI_View_All custom permission AND record access through sharing.
 * The permission alone no longer widens what is returned.
 *
 * FIELD-LEVEL SECURITY IS ENFORCED. Every query below carries WITH USER_MODE,
 * and the one dynamic query runs through Database.queryWithBinds with
 * AccessLevel.USER_MODE. Sharing decides which rows come back and says nothing
 * about which fields the running user may see - and every field here can reach
 * a language model, so the two have to be enforced separately. A user without
 * the Case_Manager_AI_Access permission set now gets a QueryException rather
 * than a briefing that is quietly missing sections.
 *
 * PII IS DELIBERATELY EXCLUDED. Bank routing numbers, account numbers, SSN and
 * Plaid access tokens are never selected, so they cannot leak into a prompt
 * sent to a language model. Creditor account numbers ARE selected, because a
 * case manager needs to identify the account, but they are masked to the last
 * four before they enter the digest. See buildDigest().
 *
 * UNTRUSTED TEXT CANNOT FORGE STRUCTURE. This digest carries its own section
 * markers, and note bodies, task subjects and email subjects are written by
 * people outside the company. See oneLine() and indentedBlock() before adding
 * any other free-text field to buildDigest().
 */
public with sharing class CaseManagerAIService {
  /** Custom permission that lets a user read every case manager's book. */
  private static final String VIEW_ALL_PERMISSION = 'Case_Manager_AI_View_All';

  /** Caps on child records pulled per case, to stay well inside heap limits. */
  private static final Integer MAX_CHILD_ROWS = 200;

  /** Schedule-item status the remaining-payments aggregate counts. */
  private static final String PSI_STATUS_SCHEDULED = 'Scheduled';
  private static final Integer MAX_ACTIVITY_ROWS = 50;
  private static final Integer MAX_EMAIL_BODY_CHARS = 500;
  /**
   * Notes are hand-written context rather than machine output, so they earn more
   * room in the digest than an email snippet does — but still bounded, because a
   * long note pasted from a chat transcript would otherwise dominate the prompt.
   */
  private static final Integer MAX_NOTE_BODY_CHARS = 1500;

  public class CaseManagerAIException extends Exception {
  }

  // ──────────────────────── describe-guarded field lists ───────────────────

  /**
   * Field names that exist on a given object in THIS org, lower-cased.
   * Cached per transaction: a describe is not free and the loaders below ask
   * repeatedly.
   */
  private static final Map<String, Set<String>> FIELD_CACHE = new Map<String, Set<String>>();

  private static Set<String> fieldsOn(String objectApiName) {
    String key = objectApiName.toLowerCase();
    if (!FIELD_CACHE.containsKey(key)) {
      Set<String> names = new Set<String>();
      SObjectType t = Schema.getGlobalDescribe().get(objectApiName);
      if (t != null) {
        for (String f : t.getDescribe().fields.getMap().keySet()) {
          names.add(f.toLowerCase());
        }
      }
      FIELD_CACHE.put(key, names);
    }
    return FIELD_CACHE.get(key);
  }

  /** The object a relationship path points at, or null if it cannot be resolved. */
  private static String targetOf(String objectApiName, String relationship) {
    SObjectType t = Schema.getGlobalDescribe().get(objectApiName);
    if (t == null) {
      return null;
    }
    String local = relationship.endsWith('__r')
      ? relationship.removeEnd('__r') + '__c'
      : relationship + 'Id';
    SObjectField f = t.getDescribe().fields.getMap().get(local.toLowerCase());
    if (f == null) {
      return null;
    }
    List<SObjectType> refs = f.getDescribe().getReferenceTo();
    return refs.isEmpty() ? null : String.valueOf(refs[0]);
  }

  /**
   * Builds a SELECT list from an allow-list, dropping anything this org lacks.
   *
   * WHY NOT FIELDS(ALL). Three reasons, in order of how quickly they bite:
   * FIELDS(ALL) is capped at LIMIT 200 and loadBook needs 500; Opportunity
   * carries 256 fields in production, so pulling every one for 500 rows is a
   * heap problem; and most importantly the PII exclusion in this class works
   * precisely BECAUSE bank routing numbers, account numbers, SSN and Plaid
   * tokens are never named in a SELECT. An allow-list fails safe - a new
   * sensitive field is excluded until someone adds it. All-fields fails open.
   *
   * What this fixes is the other half of the problem: the allow-list breaking
   * compilation when an org does not have one of the fields on it. Production
   * has no DocuSign_Tracking__c, no Payment_Schedule_Item__c.SAS_Status__c and
   * no Opportunity.Integrate_with_SAS__c, while SIT and nagadsb do. Naming a
   * missing field in static SOQL is a compile error; here it is simply skipped.
   *
   * Dotted paths are resolved properly: Account.Stage__c checks that Opportunity
   * has AccountId AND that Account has Stage__c, so a relationship into a field
   * this org lacks is dropped too.
   *
   * @param objectApiName the object being queried
   * @param desired       field names, optionally dotted relationship paths
   * @return              a comma-joined SELECT list of the fields that exist
   */
  @TestVisible
  public static String selectList(String objectApiName, List<String> desired) {
    Set<String> present = fieldsOn(objectApiName);
    List<String> kept = new List<String>();

    for (String raw : desired) {
      String field = raw.trim();
      if (String.isBlank(field)) {
        continue;
      }
      if (!field.contains('.')) {
        if (present.contains(field.toLowerCase())) {
          kept.add(field);
        }
        continue;
      }

      // Relationship path: verify the lookup here, then the field over there.
      String rel = field.substringBefore('.');
      String remainder = field.substringAfter('.');
      String localField = rel.endsWith('__r') ? rel.removeEnd('__r') + '__c' : rel + 'Id';
      if (!present.contains(localField.toLowerCase())) {
        continue;
      }
      String target = targetOf(objectApiName, rel);
      // Only single-hop remainders can be checked; deeper paths are trusted.
      if (target == null || remainder.contains('.') ||
          fieldsOn(target).contains(remainder.toLowerCase())) {
        kept.add(field);
      }
    }
    return String.join(kept, ', ');
  }

  /** True when this org has the object at all. */
  @TestVisible
  public static Boolean objectExists(String objectApiName) {
    return Schema.getGlobalDescribe().containsKey(objectApiName);
  }

  // ───────────────────────────── Entry points ─────────────────────────────

  /**
   * The current user's caseload: every Opportunity where they are the Case
   * Manager. This is the list Eli sees — 199 rows in SIT at time of writing.
   *
   * @param searchTerm optional filter on client or opportunity name
   * @param maxRows    row cap; defaults to 200, hard-capped at 500
   */
  public static List<CaseTile> getMyCases(String searchTerm, Integer maxRows) {
    Integer rowLimit = (maxRows == null || maxRows <= 0)
      ? 200
      : Math.min(maxRows, 500);

    Boolean viewAll = canViewAllCases();
    Id runningUser = UserInfo.getUserId();

    // NOTE: Case_Manager_Name__c is deliberately NOT selected. It is a
    // cross-object formula (Case_Manager__r.FirstName & " " & …LastName) that
    // compiles but throws "No such column" at runtime for users who cannot
    // traverse to the User record. resolveCaseManagerNames() fills the name in
    // from a plain User query instead.
    String soql =
      'SELECT Id, Name, AccountId, Account.Name, StageName, Amount, CloseDate, CreatedDate, ' +
      'Case_Manager__c, Client_Status__c, Client_Status_BO__c, ' +
      'Program_Type__c, Progress__c, Tier__c, State__c, Estimated_Total_Debt__c, ' +
      'Total_Program__c, EPPS_Balance__c, Net_Epps_Balance__c, EPPS_Balance_Last_Refresh__c, ' +
      'NSF_Count__c, NSF_Last_Logged_Date__c, First_Draft_Date__c, Payment_Frequency__c, ' +
      'Legal__c, Collections__c, Cancellation_Date__c, Cancellation_Reason__c, ' +
      'Doc_Submission_Status__c, Welcome_Call_Status__c, Fee_Status__c, Escrow_company__c ' +
      'FROM Opportunity WHERE ';

    // The access filter is concatenated, never taken from the caller.
    soql += viewAll ? 'Case_Manager__c != null' : 'Case_Manager__c = :runningUser';

    String term;
    if (String.isNotBlank(searchTerm)) {
      // NOT escaped: :term is a bind, and bind values are not string-substituted
      // into the query. Escaping here would put a literal backslash into the
      // search text, so a client named O'Brien would match nothing.
      term = '%' + searchTerm.trim() + '%';
      soql += ' AND (Name LIKE :term OR Account.Name LIKE :term)';
    }
    // No WITH USER_MODE in the string: the access level is supplied to
    // queryWithBinds below, and specifying it in both places is rejected at
    // runtime with "Cannot use the WITH AccessLevel clause in dynamic queries
    // that also specify an access level".
    soql += ' ORDER BY CreatedDate DESC LIMIT :rowLimit';

    // USER_MODE enforces object CRUD and field-level security. Sharing decides
    // which rows come back; it says nothing about which fields the running user
    // is allowed to see, and every field here can end up in a prompt.
    Map<String, Object> binds = new Map<String, Object>{
      'runningUser' => runningUser,
      'rowLimit' => rowLimit,
      'term' => term
    };

    List<CaseTile> tiles = new List<CaseTile>();
    // queryWithBinds returns List<SObject>; a loop variable will not narrow it
    // implicitly the way an assignment does.
    List<Opportunity> rows = (List<Opportunity>) Database.queryWithBinds(
      soql,
      binds,
      AccessLevel.USER_MODE
    );
    for (Opportunity opp : rows) {
      tiles.add(new CaseTile(opp));
    }
    resolveCaseManagerNames(tiles);
    return tiles;
  }

  /**
   * Fills in caseManagerName from the User object.
   *
   * Opportunity.Case_Manager_Name__c would be the obvious source, but it is a
   * cross-object formula and throws QueryException at runtime for users without
   * access to the referenced User fields. One extra query is a fair price for a
   * service that must never fail halfway through a briefing.
   */
  private static void resolveCaseManagerNames(List<CaseTile> tiles) {
    Set<Id> userIds = new Set<Id>();
    for (CaseTile t : tiles) {
      if (t.caseManagerId != null) {
        userIds.add(t.caseManagerId);
      }
    }
    if (userIds.isEmpty()) {
      return;
    }

    Map<Id, User> usersById = new Map<Id, User>(
      [SELECT Id, Name FROM User WHERE Id IN :userIds WITH USER_MODE]
    );
    for (CaseTile t : tiles) {
      User u = usersById.get(t.caseManagerId);
      if (u != null) {
        t.caseManagerName = u.Name;
      }
    }
  }

  /**
   * The full related-record picture for one case. Roughly 19 SOQL queries —
   * comfortably inside limits for a single case, but do NOT call this in a loop
   * over a caseload.
   */
  public static CaseContext getCaseContext(Id opportunityId) {
    Opportunity opp = assertCaseAccess(opportunityId);

    CaseContext ctx = new CaseContext();
    ctx.opportunity = new CaseTile(opp);
    resolveCaseManagerNames(new List<CaseTile>{ ctx.opportunity });
    ctx.generatedOn = System.now();
    ctx.generatedForUser = UserInfo.getName();

    Id accountId = opp.AccountId;

    loadPeopleAndCases(ctx, opportunityId, accountId);
    loadPaymentPlans(ctx, opportunityId);
    loadCreditorsAndSettlements(ctx, opportunityId);
    loadDocuSign(ctx, opportunityId, accountId);
    loadBanking(ctx, opportunityId, accountId);
    loadActivities(ctx, opportunityId, accountId);
    loadNotes(ctx, opportunityId, accountId);

    ctx.digest = buildDigest(ctx);
    return ctx;
  }

  // ───────────────────────────── Access control ────────────────────────────

  /**
   * The single gate protecting every other query in this class. Returns the
   * Opportunity only when the running user is its Case Manager (or holds the
   * view-all custom permission); throws otherwise.
   */
  @TestVisible
  private static Opportunity assertCaseAccess(Id opportunityId) {
    if (opportunityId == null) {
      throw new CaseManagerAIException('No case was specified.');
    }

    // FIELD LIST IS AN ALLOW-LIST, NOT A CONVENIENCE. Every field named here is
    // read by CaseTile and can end up in a briefing handed to a language model.
    // Do not widen it speculatively, and never replace it with a describe-driven
    // "all fields" query: bank routing numbers, account numbers, SSN and Plaid
    // tokens are kept out of prompts precisely because they are never named in a
    // SELECT, and a dynamic field list would silently undo that.
    String foundSoql =
      'SELECT ' +
      selectList(
        'Opportunity',
        new List<String>{
              'Id',
              'Name',
              'AccountId',
              'Account.Name',
              'StageName',
              'Amount',
              'CloseDate',
              'CreatedDate',
              'Case_Manager__c',
              'Client_Status__c',
              'Client_Status_BO__c',
              'Program_Type__c',
              'Progress__c',
              'Tier__c',
              'State__c',
              'Estimated_Total_Debt__c',
              'Total_Program__c',
              'Estimated_Debt_Savings__c',
              'EPPS_Balance__c',
              'Net_Epps_Balance__c',
              'EPPS_Balance_Last_Refresh__c',
              'NSF_Count__c',
              'NSF_Last_Logged_Date__c',
              'First_Draft_Date__c',
              'Payment_Frequency__c',
              'Legal__c',
              'Collections__c',
              'Cancellation_Date__c',
              'Cancellation_Reason__c',
              'Client_Hardship_Note__c',
              'Doc_Submission_Status__c',
              'Welcome_Call_Status__c',
              'Fee_Status__c',
              'Escrow_company__c'
        }
      ) +
      ' FROM Opportunity WHERE Id = :opportunityId LIMIT 1';
    List<Opportunity> found = (List<Opportunity>) Database.query(foundSoql, AccessLevel.USER_MODE);

    if (found.isEmpty()) {
      throw new CaseManagerAIException('That case no longer exists.');
    }

    Opportunity opp = found[0];
    if (!canViewAllCases() && opp.Case_Manager__c != UserInfo.getUserId()) {
      // Deliberately vague: do not confirm the record exists to a user who has
      // no business reading it.
      throw new CaseManagerAIException(
        'You do not have access to this case. Only its assigned Case Manager can view the AI briefing.'
      );
    }
    return opp;
  }

  @TestVisible
  private static Boolean canViewAllCases() {
    return FeatureManagement.checkPermission(VIEW_ALL_PERMISSION) == true;
  }

  // ───────────────────────────── Loaders ─────────────────────────────

  private static void loadPeopleAndCases(
    CaseContext ctx,
    Id opportunityId,
    Id accountId
  ) {
    ctx.contacts = new List<ContactInfo>();
    if (accountId != null) {
      for (Contact c : [
        SELECT
          Id,
          Name,
          Email,
          Phone,
          MobilePhone,
          Title,
          MailingState,
          MailingCity,
          CreatedDate
        FROM Contact
        WHERE AccountId = :accountId
        WITH USER_MODE
        ORDER BY CreatedDate DESC
        LIMIT :MAX_CHILD_ROWS
      ]) {
        ctx.contacts.add(new ContactInfo(c));
      }
    }

    ctx.serviceCases = new List<ServiceCaseInfo>();
    for (Case cse : [
      SELECT
        Id,
        CaseNumber,
        Subject,
        Status,
        Priority,
        Origin,
        Type,
        IsClosed,
        ClosedDate,
        CreatedDate,
        Description
      FROM Case
      WHERE Opportunity__c = :opportunityId OR AccountId = :accountId
      WITH USER_MODE
      ORDER BY CreatedDate DESC
      LIMIT :MAX_CHILD_ROWS
    ]) {
      ctx.serviceCases.add(new ServiceCaseInfo(cse));
    }
  }

  /**
   * RECORD-LEVEL ELEVATION — payment and settlement data only.
   *
   * WHY THIS EXISTS. Production OWD is Private on PaymentPlan__c, and a case
   * manager owns none of the plans on their own book — they belong to whoever
   * created them (checked 2026-08-19: Eli Paredes has 214 plans across 506
   * cases and record access to none of them). Under `with sharing` the Payments
   * tab therefore came back empty on every case, which reads as a broken
   * feature rather than a permissions decision.
   *
   * WHAT IS AND IS NOT RELAXED. Only the record-level sharing check is dropped,
   * and only for payment and settlement rows. Everything else still holds:
   *
   *   - The row scope is unchanged. Every caller reaches this only after
   *     assertCaseAccess() has confirmed Case_Manager__c = the running user, and
   *     every query below is bound to ids from that already-vetted case. A user
   *     cannot widen their book through this path.
   *   - Field-level security is still enforced, by stripInaccessible() on the
   *     way out rather than by USER_MODE on the way in. AccessLevel.USER_MODE
   *     could not be used here: it enforces sharing as well as FLS, so leaving
   *     it in place would have made the `without sharing` keyword do nothing.
   *   - The PII allow-lists are untouched. Bank account numbers, routing
   *     numbers, SSN and Plaid tokens are still never selected, so elevation
   *     cannot expose them.
   *   - Bank data is NOT elevated. Account_Bank_Information__c and
   *     bankconnect__Bank_Verification__c stay in the running user's sharing
   *     context deliberately.
   *
   * This class is private on purpose. It takes SOQL as a string, so exposing it
   * would hand any caller an unsharing query engine; keeping it private bounds
   * the elevation to the six queries in this file that pass through it.
   */
  private without sharing class PaymentDataReader {
    /**
     * Bind names are the parameter names below — dynamic SOQL resolves binds
     * from the local scope of whichever method calls Database.query.
     */
    List<SObject> records(
      String soql,
      Id opportunityId,
      Set<Id> planIds,
      Set<Id> creditorOppIds,
      Integer rowLimit
    ) {
      // SYSTEM_MODE is stated explicitly, not left to the single-argument
      // default. It is the whole point of this class: USER_MODE would re-apply
      // the sharing check that `without sharing` exists to drop here, and a
      // bare Database.query(soql) reads like a missing argument rather than a
      // decision. Field security is restored by stripInaccessible below.
      return Security.stripInaccessible(
          AccessType.READABLE,
          Database.query(soql, AccessLevel.SYSTEM_MODE)
        )
        .getRecords();
    }

    /**
     * Aggregates cannot be passed through stripInaccessible — an aggregate
     * names expressions rather than fields, so there is nothing to strip. These
     * return counts, dates and sums over fields Case_Manager_AI_Access already
     * grants read on.
     */
    List<AggregateResult> totals(String soql, Set<Id> planIds, String psiStatus) {
      return (List<AggregateResult>) Database.query(soql, AccessLevel.SYSTEM_MODE);
    }
  }

  private static void loadPaymentPlans(CaseContext ctx, Id opportunityId) {
    ctx.paymentPlans = new List<PaymentPlanInfo>();
    Map<Id, PaymentPlanInfo> byPlanId = new Map<Id, PaymentPlanInfo>();

    String ppSoql =
      'SELECT ' +
      selectList(
        'PaymentPlan__c',
        new List<String>{
              'Id',
              'Name',
              'Status__c',
              'Version_Number__c',
              'Version_Type__c',
              'Program_Type__c',
              'Payment_Frequency__c',
              'Total_Debt__c',
              'Total_Program_Cost__c',
              'Monthly_Payment__c',
              'Weekly_Payment__c',
              'Current_Payment__c',
              'Number_of_Payments__c',
              'First_Payment_Date__c',
              'Setup_Fee__c',
              'Program_Fee_Amount__c',
              'Schedule_Item_Count_Rollup__c',
              'Cleared_Count__c',
              'NSF_Count__c',
              'Cancelled_Count__c',
              'Total_Amount_Cleared__c',
              'Total_Draft_Amount__c',
              'Total_Savings__c',
              'Total_To_Escrow_Rollup__c',
              'First_Payment_Date_Rollup__c',
              'Last_Payment_Date_Rollup__c',
              'CreatedDate'
        }
      ) +
      ' FROM PaymentPlan__c WHERE Opportunity__c = :opportunityId ORDER BY CreatedDate DESC LIMIT :rowLimit';
    for (
      PaymentPlan__c pp : (List<PaymentPlan__c>) new PaymentDataReader()
        .records(ppSoql, opportunityId, null, null, MAX_CHILD_ROWS)
    ) {
      PaymentPlanInfo info = new PaymentPlanInfo(pp);
      byPlanId.put(pp.Id, info);
      ctx.paymentPlans.add(info);
    }

    ctx.scheduleItems = new List<ScheduleItemInfo>();
    if (byPlanId.isEmpty()) {
      return;
    }

    Set<Id> planIds = byPlanId.keySet();

    // PaymentPlan__c.Remaining_Scheduled_Payments__c is a roll-up summary, and
    // not every org has a spare roll-up slot to hold it (nagadsb is at the
    // 25-field cap). Counting here reproduces that roll-up exactly — its
    // definition is COUNT of schedule items with Status__c = 'Scheduled' — and
    // an aggregate query stays accurate even though the list below is capped
    // at MAX_CHILD_ROWS.
    // Static on purpose: an aggregate SELECT names expressions rather than
    // fields, so selectList() would have nothing to match and would strip them.
    // Every field referenced here exists in every org this deploys to.
    String remainingSoql =
      'SELECT Payment_Plan__c planId, COUNT(Id) scheduledCount' +
      ' FROM Payment_Schedule_Item__c' +
      ' WHERE Payment_Plan__c IN :planIds AND Status__c = :psiStatus' +
      ' GROUP BY Payment_Plan__c';
    for (
      AggregateResult ar : new PaymentDataReader()
        .totals(remainingSoql, planIds, PSI_STATUS_SCHEDULED)
    ) {
      PaymentPlanInfo plan = byPlanId.get((Id) ar.get('planId'));
      if (plan != null) {
        plan.remainingScheduledPayments = (Decimal) ar.get('scheduledCount');
      }
    }
    String psiSoql =
      'SELECT ' +
      selectList(
        'Payment_Schedule_Item__c',
        new List<String>{
              'Id',
              'Name',
              'Payment_Plan__c',
              'Payment_Number__c',
              'Draft_Number__c',
              'Payment_Date__c',
              'Status__c',
              'Total_Payment__c',
              'Net_Draft_Amount__c',
              'Cleared_Amount__c',
              'To_Escrow_Amount__c',
              'Escrow_Balance__c',
              'Savings_Balance__c',
              'Program_Fee_Amount__c',
              'Setup_Fee_Amount__c',
              'Banking_Fee_Amount__c',
              'Is_Program_Complete__c',
              'EPPS_EFT_Status__c',
              'EPPS_NSF_Return_Code__c',
              'EPPS_Returned_Date__c',
              'EPPS_Settlement_Date__c',
              'Void_Requested__c'
        }
      ) +
      ' FROM Payment_Schedule_Item__c WHERE Payment_Plan__c IN :planIds ORDER BY Payment_Date__c LIMIT :rowLimit';
    for (
      Payment_Schedule_Item__c psi : (List<Payment_Schedule_Item__c>) new PaymentDataReader()
        .records(psiSoql, null, planIds, null, MAX_CHILD_ROWS)
    ) {
      ScheduleItemInfo item = new ScheduleItemInfo(psi);
      ctx.scheduleItems.add(item);

      PaymentPlanInfo parent = byPlanId.get(psi.Payment_Plan__c);
      if (parent != null) {
        parent.scheduleItems.add(item);
      }
    }

    loadScheduleSummary(ctx, planIds);
  }

  /**
   * Aggregate view of the payment schedule, independent of the row cap.
   *
   * WHY THIS EXISTS. The row query above stops at MAX_CHILD_ROWS and is ordered
   * by Payment_Date__c ascending, so on a long plan the rows that get dropped
   * are the LAST payments. Production has plans of 222 and 204 items against a
   * cap of 200 (checked 2026-08-18). Summarising the truncated list would then
   * report the wrong status counts and, worse, the wrong final payment date -
   * a briefing that answers "when does this finish" with a date 22 payments too
   * early, and looks complete while doing it.
   *
   * GROUP BY returns one row per status, so this is bounded by the number of
   * statuses rather than the number of payments, and needs no cap of its own.
   */
  private static void loadScheduleSummary(CaseContext ctx, Set<Id> planIds) {
    ctx.scheduleSummary = new ScheduleSummary();
    if (planIds == null || planIds.isEmpty()) {
      return;
    }

    // Static on purpose - see the note on the aggregate in loadPaymentPlans.
    String summarySoql =
      'SELECT Status__c psiStatus, COUNT(Id) itemCount,' +
      ' MIN(Payment_Date__c) firstDate, MAX(Payment_Date__c) lastDate,' +
      ' SUM(Total_Payment__c) totalAmount' +
      ' FROM Payment_Schedule_Item__c' +
      ' WHERE Payment_Plan__c IN :planIds' +
      ' GROUP BY Status__c';
    for (
      AggregateResult ar : new PaymentDataReader()
        .totals(summarySoql, planIds, null)
    ) {
      String status = (String) ar.get('psiStatus');
      Integer count = (Integer) ar.get('itemCount');
      ctx.scheduleSummary.add(
        status,
        count,
        (Date) ar.get('firstDate'),
        (Date) ar.get('lastDate'),
        (Decimal) ar.get('totalAmount')
      );
    }
  }

  /**
   * Counts, dates and totals for the whole payment schedule.
   *
   * Every figure here comes from an aggregate query, so it stays true no matter
   * how many individual rows were loaded for display.
   */
  public class ScheduleSummary {
    @AuraEnabled
    public Integer totalItems = 0;
    @AuraEnabled
    public Map<String, Integer> countByStatus = new Map<String, Integer>();
    @AuraEnabled
    public Date firstPaymentDate;
    @AuraEnabled
    public Date lastPaymentDate;
    @AuraEnabled
    public Decimal totalScheduled = 0;

    void add(
      String status,
      Integer count,
      Date firstDate,
      Date lastDate,
      Decimal amount
    ) {
      String key = String.isBlank(status) ? 'Unspecified' : status;
      countByStatus.put(key, count == null ? 0 : count);
      totalItems += (count == null ? 0 : count);
      if (amount != null) {
        totalScheduled += amount;
      }
      if (firstDate != null && (firstPaymentDate == null || firstDate < firstPaymentDate)) {
        firstPaymentDate = firstDate;
      }
      if (lastDate != null && (lastPaymentDate == null || lastDate > lastPaymentDate)) {
        lastPaymentDate = lastDate;
      }
    }
  }

  private static void loadCreditorsAndSettlements(
    CaseContext ctx,
    Id opportunityId
  ) {
    ctx.creditors = new List<CreditorInfo>();
    Map<Id, CreditorInfo> byCreditorOppId = new Map<Id, CreditorInfo>();

    String coSoql =
      'SELECT ' +
      selectList(
        'CreditorOpportunity__c',
        new List<String>{
              'Id',
              'Name',
              'Number__c',
              'Creditor__c',
              'Creditor__r.Name',
              'CreditorAccount__c',
              'CreditorAccount__r.Name',
              'Amount__c',
              'Status__c',
              'Frequency__c',
              'Weekly_Payment__c',
              'Total_Payback__c',
              'Estimated_Settlement__c',
              'Estimated_Settlement_Payment__c',
              'Estimated_Payments_Made__c',
              'Avg_Settlement_Percentage__c',
              'Escrow_Start_Balance__c',
              'Payment_Method__c',
              'Settlement_ID__c',
              'Settlement_Memo__c',
              'Memo__c',
              'Instructions__c',
              'Ready_for_Legal__c',
              'Active_Plan__c',
              'Active_Draft_Count__c',
              'Suspended_Draft_Count__c',
              'Commission_Fee__c',
              'Max_Payment_Term_Months__c',
              'CreatedDate'
        }
      ) +
      ' FROM CreditorOpportunity__c WHERE Opportunity__c = :opportunityId ORDER BY CreatedDate DESC LIMIT :MAX_CHILD_ROWS';
    for (
      CreditorOpportunity__c co : (List<CreditorOpportunity__c>) Database.query(coSoql, AccessLevel.USER_MODE)
    ) {
      CreditorInfo info = new CreditorInfo(co);
      byCreditorOppId.put(co.Id, info);
      ctx.creditors.add(info);
    }

    ctx.settlementPlans = new List<SettlementPlanInfo>();
    ctx.settlementItems = new List<SettlementItemInfo>();
    ctx.settlementSegments = new List<SettlementSegmentInfo>();

    if (byCreditorOppId.isEmpty()) {
      return;
    }

    Set<Id> creditorOppIds = byCreditorOppId.keySet();
    Map<Id, SettlementPlanInfo> byPlanId = new Map<Id, SettlementPlanInfo>();

    String spSoql =
      'SELECT ' +
      selectList(
        'Settlement_Plan_Draft__c',
        new List<String>{
              'Id',
              'Name',
              'CreditorOpportunity__c',
              'Status__c',
              'Balance__c',
              'Current_Balance__c',
              'Settlement_Offer_Amount__c',
              'Revised_Settlement_Amount__c',
              'Settlement_Percentage__c',
              'Settlement_Savings__c',
              'Settlement_Memo__c',
              'Settlement_Term_Weeks__c',
              'Number_of_Payments__c',
              'Total_Paid_Amount__c',
              'Total_Scheduled_Amount__c',
              'Total_Processing_Amount__c',
              'Total_Commission_Fees__c',
              'Total_EPPS_Fees__c',
              'Escrow_Start_Balance__c',
              'Escrow_Shortage_Count__c',
              'Funding_Difference__c',
              'Applied_Date__c',
              'First_Payment_Date__c',
              'Next_Payment_Date__c',
              'Next_Payment_Amount__c',
              'Final_Payment_Date__c',
              'Is_Manually_Modified__c',
              'CreatedDate'
        }
      ) +
      ' FROM Settlement_Plan_Draft__c WHERE CreditorOpportunity__c IN :creditorOppIds ORDER BY CreatedDate DESC LIMIT :rowLimit';
    for (
      Settlement_Plan_Draft__c sp : (List<Settlement_Plan_Draft__c>) new PaymentDataReader()
        .records(spSoql, null, null, creditorOppIds, MAX_CHILD_ROWS)
    ) {
      SettlementPlanInfo info = new SettlementPlanInfo(sp);
      byPlanId.put(sp.Id, info);
      ctx.settlementPlans.add(info);

      CreditorInfo parent = byCreditorOppId.get(sp.CreditorOpportunity__c);
      if (parent != null) {
        parent.settlementPlans.add(info);
        if (parent.activePlanId == sp.Id) {
          parent.activePlan = info;
        }
      }
    }

    if (byPlanId.isEmpty()) {
      return;
    }

    Set<Id> planIds = byPlanId.keySet();

    String segSoql =
      'SELECT ' +
      selectList(
        'Settlement_Segment__c',
        new List<String>{
              'Id',
              'Name',
              'Settlement_Plan__c',
              'Segment_Order__c',
              'Segment_Type__c',
              'Frequency__c',
              'Payment_Amount__c',
              'Payment_Count__c',
              'Calculated_Amount__c',
              'Calculated_Count__c',
              'Segment_Total__c',
              'Start_Date__c',
              'End_Date__c',
              'Segment_Note__c',
              'Is_First_Segment__c'
        }
      ) +
      ' FROM Settlement_Segment__c WHERE Settlement_Plan__c IN :planIds ORDER BY Segment_Order__c LIMIT :MAX_CHILD_ROWS';
    for (
      Settlement_Segment__c seg : (List<Settlement_Segment__c>) Database.query(segSoql, AccessLevel.USER_MODE)
    ) {
      SettlementSegmentInfo info = new SettlementSegmentInfo(seg);
      ctx.settlementSegments.add(info);

      SettlementPlanInfo parent = byPlanId.get(seg.Settlement_Plan__c);
      if (parent != null) {
        parent.segments.add(info);
      }
    }

    String spiSoql =
      'SELECT ' +
      selectList(
        'Settlement_Plan_Item__c',
        new List<String>{
              'Id',
              'Name',
              'Settlement_Plan__c',
              'Settlement_Segment__c',
              'Payment_Number__c',
              'Payment_Date__c',
              'Original_Payment_Date__c',
              'Actual_Payment_Date__c',
              'Total_Payment__c',
              'Actual_Payment_Amount__c',
              'Status__c',
              'Payment_Method__c',
              'Escrow_Balance__c',
              'Is_Escrow_Shortage__c',
              'Skip_Payment__c',
              'Skip_Reason__c',
              'Has_Override__c',
              'Confirmation_Number__c',
              'Total_Fees__c',
              'Total_EPPS_Fee__c',
              'Rollup_Commission_Fee__c',
              'Void_Requested__c',
              'Notes__c'
        }
      ) +
      ' FROM Settlement_Plan_Item__c WHERE Settlement_Plan__c IN :planIds ORDER BY Payment_Date__c LIMIT :rowLimit';
    for (
      Settlement_Plan_Item__c spi : (List<Settlement_Plan_Item__c>) new PaymentDataReader()
        .records(spiSoql, null, planIds, null, MAX_CHILD_ROWS)
    ) {
      SettlementItemInfo info = new SettlementItemInfo(spi);
      ctx.settlementItems.add(info);

      SettlementPlanInfo parent = byPlanId.get(spi.Settlement_Plan__c);
      if (parent != null) {
        parent.items.add(info);
      }
    }
  }

  private static void loadDocuSign(
    CaseContext ctx,
    Id opportunityId,
    Id accountId
  ) {
    ctx.envelopes = new List<EnvelopeInfo>();
    Map<Id, EnvelopeInfo> byEnvelopeId = new Map<Id, EnvelopeInfo>();

    String envSoql =
      'SELECT ' +
      selectList(
        'dfsle__EnvelopeStatus__c',
        new List<String>{
              'Id',
              'Name',
              'dfsle__Status__c',
              'dfsle__EmailSubject__c',
              'dfsle__Sent__c',
              'dfsle__Completed__c',
              'dfsle__Expires__c',
              'dfsle__LastStatusUpdate__c',
              'dfsle__SenderName__c',
              'dfsle__Reason__c',
              'dfsle__DocuSignId__c'
        }
      ) +
      ' FROM dfsle__EnvelopeStatus__c WHERE dfsle__Opportunity__c = :opportunityId OR dfsle__Account__c = :accountId ORDER BY dfsle__Sent__c DESC NULLS LAST LIMIT :MAX_CHILD_ROWS';
    for (
      dfsle__EnvelopeStatus__c env : (List<dfsle__EnvelopeStatus__c>) Database.query(envSoql, AccessLevel.USER_MODE)
    ) {
      EnvelopeInfo info = new EnvelopeInfo(env);
      byEnvelopeId.put(env.Id, info);
      ctx.envelopes.add(info);
    }

    if (!byEnvelopeId.isEmpty()) {
      Set<Id> envelopeIds = byEnvelopeId.keySet();
      String recSoql =
        'SELECT ' +
        selectList(
          'dfsle__RecipientStatus__c',
          new List<String>{
                'Id',
                'Name',
                'dfsle__EnvelopeStatus__c',
                'dfsle__Status__c',
                'dfsle__Email__c',
                'dfsle__Type__c',
                'dfsle__RoutingOrder__c',
                'dfsle__Sent__c',
                'dfsle__Completed__c',
                'dfsle__Reason__c',
                'dfsle__LastStatusUpdate__c'
          }
        ) +
        ' FROM dfsle__RecipientStatus__c WHERE dfsle__EnvelopeStatus__c IN :envelopeIds ORDER BY dfsle__RoutingOrder__c LIMIT :MAX_CHILD_ROWS';
      for (
        dfsle__RecipientStatus__c rec : (List<dfsle__RecipientStatus__c>) Database.query(recSoql, AccessLevel.USER_MODE)
      ) {
        EnvelopeInfo parent = byEnvelopeId.get(rec.dfsle__EnvelopeStatus__c);
        if (parent != null) {
          parent.recipients.add(new RecipientInfo(rec));
        }
      }
    }

    // DocuSign_Tracking__c is NOT deployed to production (verified 2026-08-18:
    // absent from EntityDefinition there, present in SIT and nagadsb). It only
    // ever contributed a count, and dfsle__EnvelopeStatus__c above carries the
    // envelope and signer detail that actually matters, so the reference is
    // dropped rather than guarded — Apex cannot reference an object that does
    // not exist, even behind a runtime check. Restore this if the object is
    // ever promoted to production.
  }

  private static void loadBanking(
    CaseContext ctx,
    Id opportunityId,
    Id accountId
  ) {
    // NOTE: Routing__c and Bank_Account_Number__c are intentionally NOT
    // selected. They must never reach a language model.
    ctx.bankAccounts = new List<BankAccountInfo>();
    if (accountId != null) {
      String abiSoql =
        'SELECT ' +
        selectList(
          'Account_Bank_Information__c',
          new List<String>{
                'Id',
                'Name',
                'Bank_Name__c',
                'Bank_Account_Type__c',
                'Payment_Type__c',
                'Activate__c',
                'Account_First_Name__c',
                'Account_Last_Name__c',
                'City__c',
                'State__c',
                'SAS_Payee_Id__c',
                'SAS_Payment_Method_Set__c',
                'CreatedDate'
          }
        ) +
        ' FROM Account_Bank_Information__c WHERE Account__c = :accountId ORDER BY CreatedDate DESC LIMIT :MAX_CHILD_ROWS';
      for (
        Account_Bank_Information__c abi : (List<Account_Bank_Information__c>) Database.query(abiSoql, AccessLevel.USER_MODE)
      ) {
        ctx.bankAccounts.add(new BankAccountInfo(abi));
      }
    }

    // Plaid / Bank Connect verification. SSN and access tokens excluded.
    ctx.bankVerifications = new List<BankVerificationInfo>();
    String bvSoql =
      'SELECT ' +
      selectList(
        'bankconnect__Bank_Verification__c',
        new List<String>{
              'Id',
              'Name',
              'bankconnect__Status__c',
              'bankconnect__Status_Description__c',
              'bankconnect__Institution_Name__c',
              'bankconnect__Auth_Status__c',
              'bankconnect__Identity_Status__c',
              'bankconnect__Balance_Status__c',
              'bankconnect__Income_Status__c',
              'bankconnect__Transaction_Status__c',
              'bankconnect__Total_Bank_Account__c',
              'bankconnect__Total_Current_Balance__c',
              'bankconnect__Total_Available_Balance__c',
              'bankconnect__Average_Daily_Balance__c',
              'bankconnect__Average_Monthly_Deposit__c',
              'bankconnect__Minimum_Monthly_Deposit__c',
              'bankconnect__Average_Daily_Cash_Flow__c',
              'bankconnect__Net_Cash_Flows__c',
              'bankconnect__Total_Deposits__c',
              'bankconnect__Total_Income_Amount__c',
              'bankconnect__Total_NSF_Days__c',
              'bankconnect__Negative_Days__c',
              'bankconnect__Minimum_Balance__c',
              'bankconnect__Maximum_Balance__c',
              'bankconnect__Cash_Balance_Trend_30_Days__c',
              'bankconnect__Cash_Flow_Trend_30_Days__c',
              'bankconnect__Last_Balance_Refresh_Date__c',
              'bankconnect__Micro_Deposit_Status__c',
              'CreatedDate'
        }
      ) +
      ' FROM bankconnect__Bank_Verification__c WHERE bankconnect__Opportunity__c = :opportunityId OR bankconnect__Account__c = :accountId ORDER BY CreatedDate DESC LIMIT :MAX_CHILD_ROWS';
    for (
      bankconnect__Bank_Verification__c bv : (List<bankconnect__Bank_Verification__c>) Database.query(bvSoql, AccessLevel.USER_MODE)
    ) {
      ctx.bankVerifications.add(new BankVerificationInfo(bv));
    }

    ctx.plaidPayments = new List<PlaidPaymentInfo>();
    if (accountId != null) {
      String ppSoql =
        'SELECT ' +
        selectList(
          'bankconnect__Plaid_Payment__c',
          new List<String>{
                'Id',
                'Name',
                'bankconnect__Amount__c',
                'bankconnect__Status__c',
                'bankconnect__Payment_Type__c',
                'bankconnect__ACH_Class__c',
                'bankconnect__Currency_Code__c',
                'bankconnect__Start_Date__c',
                'bankconnect__End_Date__c',
                'bankconnect__Frequency_Interval__c',
                'bankconnect__Last_Status_Update__c',
                'bankconnect__Error_Message__c',
                'bankconnect__Error_Type__c',
                'bankconnect__Payment_Reference__c',
                'CreatedDate'
          }
        ) +
        ' FROM bankconnect__Plaid_Payment__c WHERE bankconnect__Account__c = :accountId ORDER BY CreatedDate DESC LIMIT :MAX_CHILD_ROWS';
      for (
        bankconnect__Plaid_Payment__c pp : (List<bankconnect__Plaid_Payment__c>) Database.query(ppSoql, AccessLevel.USER_MODE)
      ) {
        ctx.plaidPayments.add(new PlaidPaymentInfo(pp));
      }

      ctx.documentInsights = new List<DocumentInsightInfo>();
      String pdfSoql =
        'SELECT ' +
        selectList(
          'bankconnect__PDF_Insight__c',
          new List<String>{
                'Id',
                'Name',
                'bankconnect__Status__c',
                'bankconnect__Average_Daily_Balance__c',
                'bankconnect__Average_Monthly_Deposits__c',
                'bankconnect__Average_NSFs__c',
                'bankconnect__NSFs__c',
                'bankconnect__Negative_Weekdays__c',
                'bankconnect__Monthly_Revenue__c',
                'bankconnect__Total_Revenue__c',
                'bankconnect__Monthly_Expenses__c',
                'bankconnect__Debt_Coverage_Ratio__c',
                'bankconnect__Total_Statements__c',
                'bankconnect__Number_Of_Accounts__c',
                'CreatedDate'
          }
        ) +
        ' FROM bankconnect__PDF_Insight__c WHERE bankconnect__Account__c = :accountId ORDER BY CreatedDate DESC LIMIT :MAX_CHILD_ROWS';
      for (
        bankconnect__PDF_Insight__c pdf : (List<bankconnect__PDF_Insight__c>) Database.query(pdfSoql, AccessLevel.USER_MODE)
      ) {
        ctx.documentInsights.add(new DocumentInsightInfo(pdf));
      }
    } else {
      ctx.documentInsights = new List<DocumentInsightInfo>();
    }
  }

  private static void loadActivities(
    CaseContext ctx,
    Id opportunityId,
    Id accountId
  ) {
    Set<Id> relatedIds = new Set<Id>{ opportunityId };
    if (accountId != null) {
      relatedIds.add(accountId);
    }

    ctx.tasks = new List<TaskInfo>();
    for (Task t : [
      SELECT
        Id,
        Subject,
        Status,
        Priority,
        ActivityDate,
        Description,
        CreatedDate,
        Owner.Name,
        Who.Name
      FROM Task
      WHERE WhatId IN :relatedIds
      WITH USER_MODE
      ORDER BY CreatedDate DESC
      LIMIT :MAX_ACTIVITY_ROWS
    ]) {
      ctx.tasks.add(new TaskInfo(t));
    }

    ctx.events = new List<EventInfo>();
    for (Event e : [
      SELECT
        Id,
        Subject,
        StartDateTime,
        EndDateTime,
        Description,
        CreatedDate,
        Owner.Name
      FROM Event
      WHERE WhatId IN :relatedIds
      WITH USER_MODE
      ORDER BY StartDateTime DESC
      LIMIT :MAX_ACTIVITY_ROWS
    ]) {
      ctx.events.add(new EventInfo(e));
    }

    ctx.emails = new List<EmailInfo>();
    for (EmailMessage em : [
      SELECT
        Id,
        Subject,
        FromAddress,
        ToAddress,
        MessageDate,
        Incoming,
        Status,
        TextBody
      FROM EmailMessage
      WHERE RelatedToId IN :relatedIds
      WITH USER_MODE
      ORDER BY MessageDate DESC
      LIMIT :MAX_ACTIVITY_ROWS
    ]) {
      ctx.emails.add(new EmailInfo(em, MAX_EMAIL_BODY_CHARS));
    }

  }

  /**
   * The standard Notes related list, for both storage generations.
   *
   * This is the ONLY note source the briefing uses. The QuickNotes__c custom
   * object was removed on 2026-08-19 — DCG does not use it — so everything the
   * briefing says about notes now comes from the standard Notes related list on
   * the Opportunity and the Account, which is where hand-written case context
   * actually lives.
   *
   * Two objects, because orgs that predate Enhanced Notes carry both:
   *   - ContentNote, reached through ContentDocumentLink (Enhanced Notes)
   *   - Note, parented directly by ParentId (classic notes)
   *
   * Both are read in the running user's sharing context like everything else
   * here, so a note the user cannot see does not reach the digest.
   */
  private static void loadNotes(
    CaseContext ctx,
    Id opportunityId,
    Id accountId
  ) {
    ctx.notes = new List<NoteInfo>();

    Set<Id> linkedIds = new Set<Id>{ opportunityId };
    if (accountId != null) {
      linkedIds.add(accountId);
    }

    // Enhanced Notes. ContentDocumentLink cannot be queried without filtering on
    // LinkedEntityId or ContentDocumentId, which the WHERE clause below satisfies.
    Set<Id> noteDocIds = new Set<Id>();
    for (ContentDocumentLink cdl : [
      SELECT ContentDocumentId
      FROM ContentDocumentLink
      WHERE LinkedEntityId IN :linkedIds
      WITH USER_MODE
      LIMIT :MAX_CHILD_ROWS
    ]) {
      noteDocIds.add(cdl.ContentDocumentId);
    }

    if (!noteDocIds.isEmpty()) {
      // Filtering on Id restricts this to the linked documents that are actually
      // notes; files linked to the same records simply do not match ContentNote.
      for (ContentNote cn : [
        SELECT Id, Title, Content, CreatedDate, CreatedBy.Name
        FROM ContentNote
        WHERE Id IN :noteDocIds
        WITH USER_MODE
        ORDER BY CreatedDate DESC
        LIMIT :MAX_ACTIVITY_ROWS
      ]) {
        ctx.notes.add(new NoteInfo(cn, MAX_NOTE_BODY_CHARS));
      }
    }

    // Classic notes.
    for (Note n : [
      SELECT Id, Title, Body, ParentId, CreatedDate, CreatedBy.Name
      FROM Note
      WHERE ParentId IN :linkedIds
      WITH USER_MODE
      ORDER BY CreatedDate DESC
      LIMIT :MAX_ACTIVITY_ROWS
    ]) {
      ctx.notes.add(new NoteInfo(n, MAX_NOTE_BODY_CHARS));
    }
  }

  // ───────────────────────────── Digest ─────────────────────────────

  /**
   * Flattens the context into the plain-text briefing handed to Agentforce.
   *
   * This is the ONLY text that leaves the org for AI processing, which is why
   * the loaders above never select bank routing numbers, account numbers, SSN
   * or Plaid tokens — a field that is not queried cannot be summarised.
   */
  public static String buildDigest(CaseContext ctx) {
    CaseTile o = ctx.opportunity;
    List<String> b = new List<String>();

    b.add('=== CASE BRIEFING: ' + o.name + ' ===');
    b.add('Client: ' + blank(o.accountName));
    b.add('Case Manager: ' + blank(o.caseManagerName));
    b.add(
      'Stage: ' +
        blank(o.stageName) +
        ' | Client Status: ' +
        blank(o.clientStatus) +
        ' | Back-office Status: ' +
        blank(o.clientStatusBackOffice)
    );
    b.add(
      'Program: ' +
        blank(o.programType) +
        ' | Frequency: ' +
        blank(o.paymentFrequency) +
        ' | Escrow Co: ' +
        blank(o.escrowCompany)
    );
    b.add(
      'Enrolled Debt: ' +
        money(o.estimatedTotalDebt) +
        ' | Total Program: ' +
        money(o.totalProgram) +
        ' | Est. Savings: ' +
        money(o.estimatedDebtSavings)
    );
    b.add(
      'EPPS Balance: ' +
        money(o.eppsBalance) +
        ' (net ' +
        money(o.netEppsBalance) +
        ', refreshed ' +
        blank(o.eppsBalanceLastRefresh) +
        ')'
    );
    b.add(
      'NSF Count: ' +
        num(o.nsfCount) +
        ' | Last NSF: ' +
        blank(o.nsfLastLoggedDate) +
        ' | First Draft: ' +
        blank(o.firstDraftDate)
    );

    List<String> flags = new List<String>();
    if (o.inLegal == true) {
      flags.add('LEGAL');
    }
    if (o.inCollections == true) {
      flags.add('COLLECTIONS');
    }
    if (o.cancellationDate != null) {
      flags.add('CANCELLED ' + o.cancellationDate);
    }
    if (o.nsfCount != null && o.nsfCount >= 3) {
      flags.add('HIGH NSF');
    }
    if (!flags.isEmpty()) {
      b.add('RISK FLAGS: ' + String.join(flags, ', '));
    }
    if (String.isNotBlank(o.hardshipNote)) {
      b.add('Hardship Note: ' + o.hardshipNote);
    }

    // Payment plans
    b.add('');
    b.add('--- PAYMENT PLANS (' + ctx.paymentPlans.size() + ') ---');
    for (PaymentPlanInfo p : ctx.paymentPlans) {
      b.add(
        '* ' +
          p.name +
          ' [' +
          blank(p.status) +
          '] v' +
          num(p.versionNumber) +
          ' — ' +
          money(p.currentPayment) +
          ' ' +
          blank(p.paymentFrequency) +
          ', ' +
          num(p.numberOfPayments) +
          ' payments, total ' +
          money(p.totalProgramCost)
      );
      b.add(
        '  Cleared ' +
          num(p.clearedCount) +
          ' / NSF ' +
          num(p.nsfCount) +
          ' / Cancelled ' +
          num(p.cancelledCount) +
          ' | Collected ' +
          money(p.totalAmountCleared) +
          ' | Remaining ' +
          num(p.remainingScheduledPayments)
      );
    }

    // Schedule items — summarised from an aggregate, not from the loaded rows.
    // The row list is capped and ordered by date ascending, so counting it would
    // undercount long plans and report a final payment date that is too early.
    ScheduleSummary sum = ctx.scheduleSummary == null
      ? new ScheduleSummary()
      : ctx.scheduleSummary;
    b.add('');
    b.add('--- PAYMENT SCHEDULE ITEMS (' + sum.totalItems + ' total) ---');
    if (sum.firstPaymentDate != null) {
      b.add(
        '  Schedule runs ' +
          sum.firstPaymentDate.format() +
          ' to ' +
          sum.lastPaymentDate.format() +
          ', ' +
          money(sum.totalScheduled) +
          ' scheduled in total'
      );
    }
    for (String k : sum.countByStatus.keySet()) {
      b.add('  ' + k + ': ' + sum.countByStatus.get(k));
    }
    if (ctx.scheduleItems.size() < sum.totalItems) {
      b.add(
        '  (' +
          ctx.scheduleItems.size() +
          ' of ' +
          sum.totalItems +
          ' individual payments loaded; the counts and dates above cover all of them)'
      );
    }
    ScheduleItemInfo nextDue;
    for (ScheduleItemInfo si : ctx.scheduleItems) {
      if (
        nextDue == null &&
        si.paymentDate != null &&
        si.paymentDate >= Date.today() &&
        si.status != 'Cleared'
      ) {
        nextDue = si;
      }
    }
    if (nextDue != null) {
      b.add(
        '  Next draft: ' +
          nextDue.paymentDate +
          ' for ' +
          money(nextDue.totalPayment) +
          ' (status ' +
          blank(nextDue.status) +
          ')'
      );
    }

    // Creditors and settlements
    b.add('');
    b.add('--- ENROLLED CREDITORS (' + ctx.creditors.size() + ') ---');
    for (CreditorInfo c : ctx.creditors) {
      b.add(
        '* ' +
          blank(c.creditorName) +
          ' #' +
          blank(c.accountNumber) +
          ' — balance ' +
          money(c.amount) +
          ', status ' +
          blank(c.status) +
          ', est. settlement ' +
          money(c.estimatedSettlement) +
          ' (' +
          pct(c.avgSettlementPercentage) +
          ')'
      );
      if (c.readyForLegal == true) {
        b.add('  !! Flagged Ready for Legal');
      }
      if (String.isNotBlank(c.settlementMemo)) {
        b.add('  Memo: ' + c.settlementMemo);
      }
      for (SettlementPlanInfo sp : c.settlementPlans) {
        b.add(
          '  - Settlement Plan ' +
            sp.name +
            ' [' +
            blank(sp.status) +
            '] offer ' +
            money(sp.settlementOfferAmount) +
            ' (' +
            pct(sp.settlementPercentage) +
            '), ' +
            num(sp.numberOfPayments) +
            ' payments, paid ' +
            money(sp.totalPaidAmount) +
            ' of ' +
            money(sp.totalScheduledAmount)
        );
        b.add(
          '    Next payment ' +
            blank(sp.nextPaymentDate) +
            ' for ' +
            money(sp.nextPaymentAmount) +
            ' | Savings ' +
            money(sp.settlementSavings) +
            ' | Escrow shortages ' +
            num(sp.escrowShortageCount) +
            ' | Segments ' +
            sp.segments.size() +
            ' | Items ' +
            sp.items.size()
        );
      }
    }

    // DocuSign
    b.add('');
    b.add('--- DOCUSIGN (' + ctx.envelopes.size() + ' envelopes) ---');
    for (EnvelopeInfo e : ctx.envelopes) {
      b.add(
        '* ' +
          blank(e.emailSubject) +
          ' [' +
          blank(e.status) +
          '] sent ' +
          blank(e.sent) +
          ', completed ' +
          blank(e.completed)
      );
      for (RecipientInfo r : e.recipients) {
        b.add(
          '  - ' +
            blank(r.name) +
            ' (' +
            blank(r.recipientType) +
            '): ' +
            blank(r.status)
        );
      }
    }

    // Banking / Plaid
    b.add('');
    b.add('--- BANKING & PLAID ---');
    b.add('Bank accounts on file: ' + ctx.bankAccounts.size());
    for (BankAccountInfo ba : ctx.bankAccounts) {
      b.add(
        '* ' +
          blank(ba.bankName) +
          ' (' +
          blank(ba.accountType) +
          ', ' +
          blank(ba.paymentType) +
          ') active=' +
          ba.active
      );
    }
    for (BankVerificationInfo bv : ctx.bankVerifications) {
      b.add(
        '* Verification ' +
          blank(bv.institutionName) +
          ' [' +
          blank(bv.status) +
          '] balance ' +
          money(bv.totalCurrentBalance) +
          ', avg daily ' +
          money(bv.averageDailyBalance) +
          ', avg monthly deposit ' +
          money(bv.averageMonthlyDeposit)
      );
      b.add(
        '  NSF days ' +
          num(bv.totalNsfDays) +
          ' | negative days ' +
          num(bv.negativeDays) +
          ' | net cash flow ' +
          money(bv.netCashFlows) +
          ' | refreshed ' +
          blank(bv.lastBalanceRefresh)
      );
    }
    for (PlaidPaymentInfo pp : ctx.plaidPayments) {
      b.add(
        '* Plaid payment ' +
          money(pp.amount) +
          ' [' +
          blank(pp.status) +
          '] ' +
          blank(pp.paymentType) +
          (String.isNotBlank(pp.errorMessage)
            ? ' ERROR: ' + pp.errorMessage
            : '')
      );
    }
    for (DocumentInsightInfo di : ctx.documentInsights) {
      b.add(
        '* Document insight [' +
          blank(di.status) +
          '] avg daily balance ' +
          money(di.averageDailyBalance) +
          ', avg monthly deposits ' +
          money(di.averageMonthlyDeposits) +
          ', NSFs ' +
          num(di.nsfs)
      );
    }

    // People and service cases
    b.add('');
    b.add('--- CONTACTS (' + ctx.contacts.size() + ') ---');
    for (ContactInfo c : ctx.contacts) {
      b.add(
        '* ' +
          blank(c.name) +
          ' | ' +
          blank(c.email) +
          ' | ' +
          blank(c.phone) +
          ' | ' +
          blank(c.title)
      );
    }

    b.add('');
    b.add('--- SERVICE CASES (' + ctx.serviceCases.size() + ') ---');
    for (ServiceCaseInfo c : ctx.serviceCases) {
      b.add(
        '* ' +
          blank(c.caseNumber) +
          ' [' +
          blank(c.status) +
          '/' +
          blank(c.priority) +
          '] ' +
          blank(c.subject)
      );
    }

    // Activity
    b.add('');
    b.add(
      '--- RECENT ACTIVITY (' +
        ctx.tasks.size() +
        ' tasks, ' +
        ctx.events.size() +
        ' events, ' +
        ctx.emails.size() +
        ' emails) ---'
    );
    for (TaskInfo t : ctx.tasks) {
      b.add(
        '* TASK ' +
          blank(t.createdDate) +
          ' [' +
          blank(t.status) +
          '] ' +
          oneLine(t.subject) +
          ' — ' +
          blank(t.ownerName)
      );
    }
    for (EventInfo e : ctx.events) {
      b.add(
        '* EVENT ' + blank(e.startDateTime) + ' ' + oneLine(e.subject)
      );
    }
    for (EmailInfo e : ctx.emails) {
      b.add(
        '* EMAIL ' +
          blank(e.messageDate) +
          (e.incoming == true ? ' (inbound) ' : ' (outbound) ') +
          oneLine(e.subject)
      );
      if (String.isNotBlank(e.snippet)) {
        b.add('    ' + oneLine(e.snippet));
      }
    }
    // Notes from the standard related list. Guarded rather than assumed:
    // buildDigest is public and can be handed a context assembled by a caller
    // that predates this section.
    List<NoteInfo> noteList = ctx.notes == null
      ? new List<NoteInfo>()
      : ctx.notes;

    b.add('');
    b.add('--- NOTES (' + noteList.size() + ') ---');
    if (noteList.isEmpty()) {
      b.add('No notes on this file.');
    }
    for (NoteInfo n : noteList) {
      b.add(
        '* ' +
          oneLine(n.title) +
          ' — ' +
          blank(n.authorName) +
          ', ' +
          blank(n.createdDate) +
          ' [' +
          blank(n.source) +
          ']'
      );
      String noteBody = indentedBlock(n.body, '    ');
      if (String.isNotBlank(noteBody)) {
        b.add(noteBody);
      }
    }

    return String.join(b, '\n');
  }

  // ───────────────────────────── Formatting helpers ────────────────────────

  private static String blank(Object v) {
    return v == null ? '—' : String.valueOf(v);
  }

  /**
   * Flattens a free-text value onto one line.
   *
   * WHY. This digest is plain text with structure of its own: sections are
   * '--- NAME (n) ---' and rows begin with '* '. Task subjects, email subjects
   * and note bodies are written by people outside the company, and a value
   * carrying a newline can therefore draw a section header of its own. The
   * result goes straight to the Agentforce planner, which has no way to tell a
   * forged section from a real one, so the newline is removed here rather than
   * trusted to a downstream instruction.
   */
  private static String oneLine(Object v) {
    if (v == null) {
      return '—';
    }
    String s = String.valueOf(v).replaceAll('[\\r\\n]+', ' ').trim();
    return String.isBlank(s) ? '—' : s.replaceAll(' {2,}', ' ');
  }

  /**
   * Renders a multi-line body as an indented block that cannot forge structure.
   *
   * Note bodies are genuinely multi-line and a case manager reads them, so
   * flattening them the way oneLine() does would cost real information. Instead
   * every line keeps its own row but is indented and stripped of the leading
   * punctuation this format uses as markers, so a line reading
   * '--- SERVICE CASES (1) ---' inside a note stays visibly inside the note.
   */
  private static String indentedBlock(String body, String pad) {
    if (String.isBlank(body)) {
      return null;
    }
    List<String> rendered = new List<String>();
    for (String raw : body.split('\\r?\\n')) {
      String line = raw.trim().replaceFirst('^[-*#>=~\\s]+', '');
      if (String.isNotBlank(line)) {
        rendered.add(pad + line);
      }
    }
    return rendered.isEmpty() ? null : String.join(rendered, '\n');
  }

  private static String money(Decimal v) {
    return v == null ? '—' : '$' + v.setScale(2).format();
  }

  private static String num(Decimal v) {
    return v == null ? '0' : String.valueOf(v.setScale(0));
  }

  private static String pct(Decimal v) {
    return v == null ? '—' : v.setScale(2) + '%';
  }

  // ───────────────────────────── Wrappers ─────────────────────────────

  public class CaseContext {
    @AuraEnabled
    public CaseTile opportunity;
    @AuraEnabled
    public List<ContactInfo> contacts;
    @AuraEnabled
    public List<ServiceCaseInfo> serviceCases;
    @AuraEnabled
    public List<PaymentPlanInfo> paymentPlans;
    @AuraEnabled
    public List<ScheduleItemInfo> scheduleItems;
    @AuraEnabled
    public ScheduleSummary scheduleSummary;
    @AuraEnabled
    public List<CreditorInfo> creditors;
    @AuraEnabled
    public List<SettlementPlanInfo> settlementPlans;
    @AuraEnabled
    public List<SettlementItemInfo> settlementItems;
    @AuraEnabled
    public List<SettlementSegmentInfo> settlementSegments;
    @AuraEnabled
    public List<EnvelopeInfo> envelopes;
    @AuraEnabled
    public List<BankAccountInfo> bankAccounts;
    @AuraEnabled
    public List<BankVerificationInfo> bankVerifications;
    @AuraEnabled
    public List<PlaidPaymentInfo> plaidPayments;
    @AuraEnabled
    public List<DocumentInsightInfo> documentInsights;
    @AuraEnabled
    public List<TaskInfo> tasks;
    @AuraEnabled
    public List<EventInfo> events;
    @AuraEnabled
    public List<EmailInfo> emails;
    /** Notes from the standard related list — ContentNote and classic Note. */
    @AuraEnabled
    public List<NoteInfo> notes;
    @AuraEnabled
    public String digest;
    @AuraEnabled
    public Datetime generatedOn;
    @AuraEnabled
    public String generatedForUser;
  }

  public class CaseTile {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public Id accountId;
    @AuraEnabled
    public String accountName;
    @AuraEnabled
    public String stageName;
    @AuraEnabled
    public Decimal amount;
    @AuraEnabled
    public Date closeDate;
    @AuraEnabled
    public Datetime createdDate;
    @AuraEnabled
    public Id caseManagerId;
    @AuraEnabled
    public String caseManagerName;
    @AuraEnabled
    public String clientStatus;
    @AuraEnabled
    public String clientStatusBackOffice;
    @AuraEnabled
    public String programType;
    @AuraEnabled
    public String progress;
    @AuraEnabled
    public String tier;
    @AuraEnabled
    public String state;
    @AuraEnabled
    public String escrowCompany;
    @AuraEnabled
    public String paymentFrequency;
    @AuraEnabled
    public Decimal estimatedTotalDebt;
    @AuraEnabled
    public Decimal totalProgram;
    @AuraEnabled
    public Decimal estimatedDebtSavings;
    @AuraEnabled
    public Decimal eppsBalance;
    @AuraEnabled
    public Decimal netEppsBalance;
    @AuraEnabled
    public Datetime eppsBalanceLastRefresh;
    @AuraEnabled
    public Decimal nsfCount;
    @AuraEnabled
    public Date nsfLastLoggedDate;
    @AuraEnabled
    public Date firstDraftDate;
    // Legal__c and Collections__c are User lookups, not checkboxes — they hold
    // the assigned legal / collections rep. A populated value is what marks the
    // case as being in that track, which is what the derived booleans express.
    @AuraEnabled
    public Id legalUserId;
    @AuraEnabled
    public Id collectionsUserId;
    @AuraEnabled
    public Boolean inLegal;
    @AuraEnabled
    public Boolean inCollections;
    @AuraEnabled
    public Date cancellationDate;
    @AuraEnabled
    public String cancellationReason;
    @AuraEnabled
    public String hardshipNote;
    @AuraEnabled
    public String docSubmissionStatus;
    @AuraEnabled
    public String welcomeCallStatus;
    @AuraEnabled
    public String feeStatus;
    @AuraEnabled
    public String riskLevel;

    public CaseTile(Opportunity o) {
      this.id = o.Id;
      this.name = o.Name;
      this.accountId = o.AccountId;
      this.accountName = o.Account != null ? o.Account.Name : null;
      this.stageName = o.StageName;
      this.amount = o.Amount;
      this.closeDate = o.CloseDate;
      this.createdDate = o.CreatedDate;
      this.caseManagerId = o.Case_Manager__c;
      // caseManagerName is populated by resolveCaseManagerNames().
      this.clientStatus = o.Client_Status__c;
      this.clientStatusBackOffice = o.Client_Status_BO__c;
      this.programType = o.Program_Type__c;
      this.progress = o.Progress__c;
      this.tier = o.Tier__c;
      this.state = o.State__c;
      this.escrowCompany = o.Escrow_company__c;
      this.paymentFrequency = o.Payment_Frequency__c;
      this.estimatedTotalDebt = o.Estimated_Total_Debt__c;
      this.totalProgram = o.Total_Program__c;
      this.eppsBalance = o.EPPS_Balance__c;
      this.netEppsBalance = o.Net_Epps_Balance__c;
      this.eppsBalanceLastRefresh = o.EPPS_Balance_Last_Refresh__c;
      this.nsfCount = o.NSF_Count__c;
      this.nsfLastLoggedDate = o.NSF_Last_Logged_Date__c;
      this.firstDraftDate = o.First_Draft_Date__c;
      this.legalUserId = o.Legal__c;
      this.collectionsUserId = o.Collections__c;
      this.inLegal = o.Legal__c != null;
      this.inCollections = o.Collections__c != null;
      this.cancellationDate = o.Cancellation_Date__c;
      this.cancellationReason = o.Cancellation_Reason__c;
      this.docSubmissionStatus = o.Doc_Submission_Status__c;
      this.welcomeCallStatus = o.Welcome_Call_Status__c;
      this.feeStatus = o.Fee_Status__c;

      // Fields only present on the deep query — guard so the list view, which
      // selects a narrower field set, does not blow up.
      this.estimatedDebtSavings = safeDecimal(o, 'Estimated_Debt_Savings__c');
      this.hardshipNote = safeString(o, 'Client_Hardship_Note__c');

      this.riskLevel = deriveRisk();
    }

    private String deriveRisk() {
      if (cancellationDate != null || inLegal == true) {
        return 'High';
      }
      if ((nsfCount != null && nsfCount >= 3) || inCollections == true) {
        return 'High';
      }
      if (nsfCount != null && nsfCount > 0) {
        return 'Medium';
      }
      return 'Low';
    }
  }

  private static Decimal safeDecimal(SObject rec, String field) {
    try {
      return (Decimal) rec.get(field);
    } catch (Exception e) {
      return null;
    }
  }

  private static String safeString(SObject rec, String field) {
    try {
      return (String) rec.get(field);
    } catch (Exception e) {
      return null;
    }
  }

  public class ContactInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String email;
    @AuraEnabled
    public String phone;
    @AuraEnabled
    public String mobilePhone;
    @AuraEnabled
    public String title;
    @AuraEnabled
    public String mailingState;
    @AuraEnabled
    public String mailingCity;

    public ContactInfo(Contact c) {
      this.id = c.Id;
      this.name = c.Name;
      this.email = c.Email;
      this.phone = c.Phone;
      this.mobilePhone = c.MobilePhone;
      this.title = c.Title;
      this.mailingState = c.MailingState;
      this.mailingCity = c.MailingCity;
    }
  }

  public class ServiceCaseInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String caseNumber;
    @AuraEnabled
    public String subject;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String priority;
    @AuraEnabled
    public String origin;
    @AuraEnabled
    public String caseType;
    @AuraEnabled
    public Boolean isClosed;
    @AuraEnabled
    public Datetime closedDate;
    @AuraEnabled
    public Datetime createdDate;

    public ServiceCaseInfo(Case c) {
      this.id = c.Id;
      this.caseNumber = c.CaseNumber;
      this.subject = c.Subject;
      this.status = c.Status;
      this.priority = c.Priority;
      this.origin = c.Origin;
      this.caseType = c.Type;
      this.isClosed = c.IsClosed;
      this.closedDate = c.ClosedDate;
      this.createdDate = c.CreatedDate;
    }
  }

  public class PaymentPlanInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Decimal versionNumber;
    @AuraEnabled
    public String versionType;
    @AuraEnabled
    public String programType;
    @AuraEnabled
    public String paymentFrequency;
    @AuraEnabled
    public Decimal totalDebt;
    @AuraEnabled
    public Decimal totalProgramCost;
    @AuraEnabled
    public Decimal monthlyPayment;
    @AuraEnabled
    public Decimal weeklyPayment;
    @AuraEnabled
    public Decimal currentPayment;
    @AuraEnabled
    public Decimal numberOfPayments;
    @AuraEnabled
    public Date firstPaymentDate;
    @AuraEnabled
    public Decimal setupFee;
    @AuraEnabled
    public Decimal programFeeAmount;
    @AuraEnabled
    public Decimal clearedCount;
    @AuraEnabled
    public Decimal nsfCount;
    @AuraEnabled
    public Decimal cancelledCount;
    @AuraEnabled
    public Decimal totalAmountCleared;
    @AuraEnabled
    public Decimal totalDraftAmount;
    @AuraEnabled
    public Decimal totalSavings;
    @AuraEnabled
    public Decimal totalToEscrow;
    @AuraEnabled
    public Decimal remainingScheduledPayments;
    @AuraEnabled
    public Date lastPaymentDate;
    @AuraEnabled
    public List<ScheduleItemInfo> scheduleItems = new List<ScheduleItemInfo>();

    public PaymentPlanInfo(PaymentPlan__c p) {
      this.id = p.Id;
      this.name = p.Name;
      this.status = p.Status__c;
      this.versionNumber = p.Version_Number__c;
      this.versionType = p.Version_Type__c;
      this.programType = p.Program_Type__c;
      this.paymentFrequency = p.Payment_Frequency__c;
      this.totalDebt = p.Total_Debt__c;
      this.totalProgramCost = p.Total_Program_Cost__c;
      this.monthlyPayment = p.Monthly_Payment__c;
      this.weeklyPayment = p.Weekly_Payment__c;
      this.currentPayment = p.Current_Payment__c;
      this.numberOfPayments = p.Number_of_Payments__c;
      this.firstPaymentDate = p.First_Payment_Date__c;
      this.setupFee = p.Setup_Fee__c;
      this.programFeeAmount = p.Program_Fee_Amount__c;
      this.clearedCount = p.Cleared_Count__c;
      this.nsfCount = p.NSF_Count__c;
      this.cancelledCount = p.Cancelled_Count__c;
      this.totalAmountCleared = p.Total_Amount_Cleared__c;
      this.totalDraftAmount = p.Total_Draft_Amount__c;
      this.totalSavings = p.Total_Savings__c;
      this.totalToEscrow = p.Total_To_Escrow_Rollup__c;
      // remainingScheduledPayments is computed in loadPaymentPlans().
      this.lastPaymentDate = p.Last_Payment_Date_Rollup__c;
    }
  }

  public class ScheduleItemInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public Id paymentPlanId;
    @AuraEnabled
    public Decimal paymentNumber;
    @AuraEnabled
    public String draftNumber;
    @AuraEnabled
    public Date paymentDate;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Decimal totalPayment;
    @AuraEnabled
    public Decimal netDraftAmount;
    @AuraEnabled
    public Decimal clearedAmount;
    @AuraEnabled
    public Decimal toEscrowAmount;
    @AuraEnabled
    public Decimal escrowBalance;
    @AuraEnabled
    public Decimal savingsBalance;
    @AuraEnabled
    public Decimal programFeeAmount;
    @AuraEnabled
    public Decimal setupFeeAmount;
    @AuraEnabled
    public Decimal bankingFeeAmount;
    @AuraEnabled
    public String eppsStatus;
    @AuraEnabled
    public String eppsReturnCode;
    @AuraEnabled
    public Datetime eppsReturnedDate;
    @AuraEnabled
    public Boolean voidRequested;

    public ScheduleItemInfo(Payment_Schedule_Item__c s) {
      this.id = s.Id;
      this.name = s.Name;
      this.paymentPlanId = s.Payment_Plan__c;
      this.paymentNumber = s.Payment_Number__c;
      this.draftNumber = s.Draft_Number__c;
      this.paymentDate = s.Payment_Date__c;
      this.status = s.Status__c;
      this.totalPayment = s.Total_Payment__c;
      this.netDraftAmount = s.Net_Draft_Amount__c;
      this.clearedAmount = s.Cleared_Amount__c;
      this.toEscrowAmount = s.To_Escrow_Amount__c;
      this.escrowBalance = s.Escrow_Balance__c;
      this.savingsBalance = s.Savings_Balance__c;
      this.programFeeAmount = s.Program_Fee_Amount__c;
      this.setupFeeAmount = s.Setup_Fee_Amount__c;
      this.bankingFeeAmount = s.Banking_Fee_Amount__c;
      this.eppsStatus = s.EPPS_EFT_Status__c;
      this.eppsReturnCode = s.EPPS_NSF_Return_Code__c;
      this.eppsReturnedDate = s.EPPS_Returned_Date__c;
      this.voidRequested = s.Void_Requested__c;
    }
  }

  public class CreditorInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String creditorName;
    @AuraEnabled
    public String accountNumber;
    @AuraEnabled
    public Decimal amount;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String frequency;
    @AuraEnabled
    public Decimal weeklyPayment;
    @AuraEnabled
    public Decimal totalPayback;
    @AuraEnabled
    public Decimal estimatedSettlement;
    @AuraEnabled
    public Decimal estimatedSettlementPayment;
    @AuraEnabled
    public Decimal estimatedPaymentsMade;
    @AuraEnabled
    public Decimal avgSettlementPercentage;
    @AuraEnabled
    public Decimal escrowStartBalance;
    @AuraEnabled
    public String paymentMethod;
    @AuraEnabled
    public String settlementId;
    @AuraEnabled
    public String settlementMemo;
    @AuraEnabled
    public String memo;
    @AuraEnabled
    public Boolean readyForLegal;
    @AuraEnabled
    public Id activePlanId;
    @AuraEnabled
    public Decimal activeDraftCount;
    @AuraEnabled
    public Decimal suspendedDraftCount;
    @AuraEnabled
    public SettlementPlanInfo activePlan;
    @AuraEnabled
    public List<SettlementPlanInfo> settlementPlans = new List<SettlementPlanInfo>();

    public CreditorInfo(CreditorOpportunity__c c) {
      this.id = c.Id;
      this.name = c.Name;
      this.creditorName = c.Creditor__r != null
        ? c.Creditor__r.Name
        : (c.CreditorAccount__r != null ? c.CreditorAccount__r.Name : c.Name);
      // Last four only. A case manager identifies the account from this on a
      // call; the full number is the same class of data as the bank account and
      // routing numbers this service already refuses to select, and it ends up
      // in an LLM-facing briefing.
      this.accountNumber = String.isBlank(c.Number__c)
        ? null
        : '****' + c.Number__c.right(4);
      this.amount = c.Amount__c;
      this.status = c.Status__c;
      this.frequency = c.Frequency__c;
      this.weeklyPayment = c.Weekly_Payment__c;
      this.totalPayback = c.Total_Payback__c;
      this.estimatedSettlement = c.Estimated_Settlement__c;
      this.estimatedSettlementPayment = c.Estimated_Settlement_Payment__c;
      this.estimatedPaymentsMade = c.Estimated_Payments_Made__c;
      this.avgSettlementPercentage = c.Avg_Settlement_Percentage__c;
      this.escrowStartBalance = c.Escrow_Start_Balance__c;
      this.paymentMethod = c.Payment_Method__c;
      this.settlementId = c.Settlement_ID__c;
      this.settlementMemo = c.Settlement_Memo__c;
      this.memo = c.Memo__c;
      this.readyForLegal = c.Ready_for_Legal__c;
      this.activePlanId = c.Active_Plan__c;
      this.activeDraftCount = c.Active_Draft_Count__c;
      this.suspendedDraftCount = c.Suspended_Draft_Count__c;
    }
  }

  public class SettlementPlanInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public Id creditorOpportunityId;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Decimal balance;
    @AuraEnabled
    public Decimal currentBalance;
    @AuraEnabled
    public Decimal settlementOfferAmount;
    @AuraEnabled
    public Decimal revisedSettlementAmount;
    @AuraEnabled
    public Decimal settlementPercentage;
    @AuraEnabled
    public Decimal settlementSavings;
    @AuraEnabled
    public String settlementMemo;
    @AuraEnabled
    public Decimal settlementTermWeeks;
    @AuraEnabled
    public Decimal numberOfPayments;
    @AuraEnabled
    public Decimal totalPaidAmount;
    @AuraEnabled
    public Decimal totalScheduledAmount;
    @AuraEnabled
    public Decimal totalProcessingAmount;
    @AuraEnabled
    public Decimal totalCommissionFees;
    @AuraEnabled
    public Decimal totalEppsFees;
    @AuraEnabled
    public Decimal escrowStartBalance;
    @AuraEnabled
    public Decimal escrowShortageCount;
    @AuraEnabled
    public Decimal fundingDifference;
    @AuraEnabled
    public Datetime appliedDate;
    @AuraEnabled
    public Date firstPaymentDate;
    @AuraEnabled
    public Date nextPaymentDate;
    @AuraEnabled
    public Decimal nextPaymentAmount;
    @AuraEnabled
    public Date finalPaymentDate;
    @AuraEnabled
    public Boolean isManuallyModified;
    @AuraEnabled
    public List<SettlementSegmentInfo> segments = new List<SettlementSegmentInfo>();
    @AuraEnabled
    public List<SettlementItemInfo> items = new List<SettlementItemInfo>();

    public SettlementPlanInfo(Settlement_Plan_Draft__c s) {
      this.id = s.Id;
      this.name = s.Name;
      this.creditorOpportunityId = s.CreditorOpportunity__c;
      this.status = s.Status__c;
      this.balance = s.Balance__c;
      this.currentBalance = s.Current_Balance__c;
      this.settlementOfferAmount = s.Settlement_Offer_Amount__c;
      this.revisedSettlementAmount = s.Revised_Settlement_Amount__c;
      this.settlementPercentage = s.Settlement_Percentage__c;
      this.settlementSavings = s.Settlement_Savings__c;
      this.settlementMemo = s.Settlement_Memo__c;
      this.settlementTermWeeks = s.Settlement_Term_Weeks__c;
      this.numberOfPayments = s.Number_of_Payments__c;
      this.totalPaidAmount = s.Total_Paid_Amount__c;
      this.totalScheduledAmount = s.Total_Scheduled_Amount__c;
      this.totalProcessingAmount = s.Total_Processing_Amount__c;
      this.totalCommissionFees = s.Total_Commission_Fees__c;
      this.totalEppsFees = s.Total_EPPS_Fees__c;
      this.escrowStartBalance = s.Escrow_Start_Balance__c;
      this.escrowShortageCount = s.Escrow_Shortage_Count__c;
      this.fundingDifference = s.Funding_Difference__c;
      this.appliedDate = s.Applied_Date__c;
      this.firstPaymentDate = s.First_Payment_Date__c;
      this.nextPaymentDate = s.Next_Payment_Date__c;
      this.nextPaymentAmount = s.Next_Payment_Amount__c;
      this.finalPaymentDate = s.Final_Payment_Date__c;
      this.isManuallyModified = s.Is_Manually_Modified__c;
    }
  }

  public class SettlementSegmentInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public Id settlementPlanId;
    @AuraEnabled
    public Decimal segmentOrder;
    @AuraEnabled
    public String segmentType;
    @AuraEnabled
    public String frequency;
    @AuraEnabled
    public Decimal paymentAmount;
    @AuraEnabled
    public Decimal paymentCount;
    @AuraEnabled
    public Decimal calculatedAmount;
    @AuraEnabled
    public Decimal calculatedCount;
    @AuraEnabled
    public Decimal segmentTotal;
    @AuraEnabled
    public Date startDate;
    @AuraEnabled
    public Date endDate;
    @AuraEnabled
    public String note;
    @AuraEnabled
    public Boolean isFirstSegment;

    public SettlementSegmentInfo(Settlement_Segment__c s) {
      this.id = s.Id;
      this.name = s.Name;
      this.settlementPlanId = s.Settlement_Plan__c;
      this.segmentOrder = s.Segment_Order__c;
      this.segmentType = s.Segment_Type__c;
      this.frequency = s.Frequency__c;
      this.paymentAmount = s.Payment_Amount__c;
      this.paymentCount = s.Payment_Count__c;
      this.calculatedAmount = s.Calculated_Amount__c;
      this.calculatedCount = s.Calculated_Count__c;
      this.segmentTotal = s.Segment_Total__c;
      this.startDate = s.Start_Date__c;
      this.endDate = s.End_Date__c;
      this.note = s.Segment_Note__c;
      this.isFirstSegment = s.Is_First_Segment__c;
    }
  }

  public class SettlementItemInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public Id settlementPlanId;
    @AuraEnabled
    public Id settlementSegmentId;
    @AuraEnabled
    public Decimal paymentNumber;
    @AuraEnabled
    public Date paymentDate;
    @AuraEnabled
    public Date originalPaymentDate;
    @AuraEnabled
    public Date actualPaymentDate;
    @AuraEnabled
    public Decimal totalPayment;
    @AuraEnabled
    public Decimal actualPaymentAmount;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String paymentMethod;
    @AuraEnabled
    public Decimal escrowBalance;
    @AuraEnabled
    public Boolean isEscrowShortage;
    @AuraEnabled
    public Boolean skipPayment;
    @AuraEnabled
    public String skipReason;
    @AuraEnabled
    public Boolean hasOverride;
    @AuraEnabled
    public String confirmationNumber;
    @AuraEnabled
    public Decimal totalFees;
    @AuraEnabled
    public Decimal totalEppsFee;
    @AuraEnabled
    public Decimal commissionFee;
    @AuraEnabled
    public Boolean voidRequested;
    @AuraEnabled
    public String notes;

    public SettlementItemInfo(Settlement_Plan_Item__c s) {
      this.id = s.Id;
      this.name = s.Name;
      this.settlementPlanId = s.Settlement_Plan__c;
      this.settlementSegmentId = s.Settlement_Segment__c;
      this.paymentNumber = s.Payment_Number__c;
      this.paymentDate = s.Payment_Date__c;
      this.originalPaymentDate = s.Original_Payment_Date__c;
      this.actualPaymentDate = s.Actual_Payment_Date__c;
      this.totalPayment = s.Total_Payment__c;
      this.actualPaymentAmount = s.Actual_Payment_Amount__c;
      this.status = s.Status__c;
      this.paymentMethod = s.Payment_Method__c;
      this.escrowBalance = s.Escrow_Balance__c;
      this.isEscrowShortage = s.Is_Escrow_Shortage__c;
      this.skipPayment = s.Skip_Payment__c;
      this.skipReason = s.Skip_Reason__c;
      this.hasOverride = s.Has_Override__c;
      this.confirmationNumber = s.Confirmation_Number__c;
      this.totalFees = s.Total_Fees__c;
      this.totalEppsFee = s.Total_EPPS_Fee__c;
      this.commissionFee = s.Rollup_Commission_Fee__c;
      this.voidRequested = s.Void_Requested__c;
      this.notes = s.Notes__c;
    }
  }

  public class EnvelopeInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String emailSubject;
    @AuraEnabled
    public Datetime sent;
    @AuraEnabled
    public Datetime completed;
    @AuraEnabled
    public Datetime expires;
    @AuraEnabled
    public Datetime lastStatusUpdate;
    @AuraEnabled
    public String senderName;
    @AuraEnabled
    public String reason;
    @AuraEnabled
    public String docuSignId;
    @AuraEnabled
    public List<RecipientInfo> recipients = new List<RecipientInfo>();

    public EnvelopeInfo(dfsle__EnvelopeStatus__c e) {
      this.id = e.Id;
      this.name = e.Name;
      this.status = e.dfsle__Status__c;
      this.emailSubject = e.dfsle__EmailSubject__c;
      this.sent = e.dfsle__Sent__c;
      this.completed = e.dfsle__Completed__c;
      this.expires = e.dfsle__Expires__c;
      this.lastStatusUpdate = e.dfsle__LastStatusUpdate__c;
      this.senderName = e.dfsle__SenderName__c;
      this.reason = e.dfsle__Reason__c;
      this.docuSignId = e.dfsle__DocuSignId__c;
    }
  }

  public class RecipientInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String email;
    @AuraEnabled
    public String recipientType;
    @AuraEnabled
    public Decimal routingOrder;
    @AuraEnabled
    public Datetime sent;
    @AuraEnabled
    public Datetime completed;
    @AuraEnabled
    public String reason;

    public RecipientInfo(dfsle__RecipientStatus__c r) {
      this.id = r.Id;
      this.name = r.Name;
      this.status = r.dfsle__Status__c;
      this.email = r.dfsle__Email__c;
      this.recipientType = r.dfsle__Type__c;
      this.routingOrder = r.dfsle__RoutingOrder__c;
      this.sent = r.dfsle__Sent__c;
      this.completed = r.dfsle__Completed__c;
      this.reason = r.dfsle__Reason__c;
    }
  }

  public class BankAccountInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String bankName;
    @AuraEnabled
    public String accountType;
    @AuraEnabled
    public String paymentType;
    @AuraEnabled
    public Boolean active;
    @AuraEnabled
    public String accountHolder;
    @AuraEnabled
    public String city;
    @AuraEnabled
    public String state;
    @AuraEnabled
    public String sasPayeeId;

    public BankAccountInfo(Account_Bank_Information__c a) {
      this.id = a.Id;
      this.name = a.Name;
      this.bankName = a.Bank_Name__c;
      this.accountType = a.Bank_Account_Type__c;
      this.paymentType = a.Payment_Type__c;
      this.active = a.Activate__c;
      this.accountHolder = String.join(
        new List<String>{
          a.Account_First_Name__c == null ? '' : a.Account_First_Name__c,
          a.Account_Last_Name__c == null ? '' : a.Account_Last_Name__c
        },
        ' '
      ).trim();
      this.city = a.City__c;
      this.state = a.State__c;
      this.sasPayeeId = a.SAS_Payee_Id__c;
    }
  }

  public class BankVerificationInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String statusDescription;
    @AuraEnabled
    public String institutionName;
    @AuraEnabled
    public String authStatus;
    @AuraEnabled
    public String identityStatus;
    @AuraEnabled
    public String balanceStatus;
    @AuraEnabled
    public String incomeStatus;
    @AuraEnabled
    public String transactionStatus;
    @AuraEnabled
    public Decimal totalBankAccounts;
    @AuraEnabled
    public Decimal totalCurrentBalance;
    @AuraEnabled
    public Decimal totalAvailableBalance;
    @AuraEnabled
    public Decimal averageDailyBalance;
    @AuraEnabled
    public Decimal averageMonthlyDeposit;
    @AuraEnabled
    public Decimal minimumMonthlyDeposit;
    @AuraEnabled
    public Decimal averageDailyCashFlow;
    @AuraEnabled
    public Decimal netCashFlows;
    @AuraEnabled
    public Decimal totalDeposits;
    @AuraEnabled
    public Decimal totalIncomeAmount;
    @AuraEnabled
    public Decimal totalNsfDays;
    @AuraEnabled
    public Decimal negativeDays;
    @AuraEnabled
    public Decimal minimumBalance;
    @AuraEnabled
    public Decimal maximumBalance;
    @AuraEnabled
    public Decimal cashBalanceTrend30;
    @AuraEnabled
    public Decimal cashFlowTrend30;
    @AuraEnabled
    public Datetime lastBalanceRefresh;
    @AuraEnabled
    public String microDepositStatus;

    public BankVerificationInfo(bankconnect__Bank_Verification__c b) {
      this.id = b.Id;
      this.name = b.Name;
      this.status = b.bankconnect__Status__c;
      this.statusDescription = b.bankconnect__Status_Description__c;
      this.institutionName = b.bankconnect__Institution_Name__c;
      this.authStatus = b.bankconnect__Auth_Status__c;
      this.identityStatus = b.bankconnect__Identity_Status__c;
      this.balanceStatus = b.bankconnect__Balance_Status__c;
      this.incomeStatus = b.bankconnect__Income_Status__c;
      this.transactionStatus = b.bankconnect__Transaction_Status__c;
      this.totalBankAccounts = b.bankconnect__Total_Bank_Account__c;
      this.totalCurrentBalance = b.bankconnect__Total_Current_Balance__c;
      this.totalAvailableBalance = b.bankconnect__Total_Available_Balance__c;
      this.averageDailyBalance = b.bankconnect__Average_Daily_Balance__c;
      this.averageMonthlyDeposit = b.bankconnect__Average_Monthly_Deposit__c;
      this.minimumMonthlyDeposit = b.bankconnect__Minimum_Monthly_Deposit__c;
      this.averageDailyCashFlow = b.bankconnect__Average_Daily_Cash_Flow__c;
      this.netCashFlows = b.bankconnect__Net_Cash_Flows__c;
      this.totalDeposits = b.bankconnect__Total_Deposits__c;
      this.totalIncomeAmount = b.bankconnect__Total_Income_Amount__c;
      this.totalNsfDays = b.bankconnect__Total_NSF_Days__c;
      this.negativeDays = b.bankconnect__Negative_Days__c;
      this.minimumBalance = b.bankconnect__Minimum_Balance__c;
      this.maximumBalance = b.bankconnect__Maximum_Balance__c;
      this.cashBalanceTrend30 = b.bankconnect__Cash_Balance_Trend_30_Days__c;
      this.cashFlowTrend30 = b.bankconnect__Cash_Flow_Trend_30_Days__c;
      this.lastBalanceRefresh = b.bankconnect__Last_Balance_Refresh_Date__c;
      this.microDepositStatus = b.bankconnect__Micro_Deposit_Status__c;
    }
  }

  public class PlaidPaymentInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public Decimal amount;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String paymentType;
    @AuraEnabled
    public String achClass;
    @AuraEnabled
    public String currencyCode;
    @AuraEnabled
    public Date startDate;
    @AuraEnabled
    public Date endDate;
    @AuraEnabled
    public String frequencyInterval;
    @AuraEnabled
    public Datetime lastStatusUpdate;
    @AuraEnabled
    public String errorMessage;
    @AuraEnabled
    public String errorType;
    @AuraEnabled
    public String paymentReference;

    public PlaidPaymentInfo(bankconnect__Plaid_Payment__c p) {
      this.id = p.Id;
      this.name = p.Name;
      this.amount = p.bankconnect__Amount__c;
      this.status = p.bankconnect__Status__c;
      this.paymentType = p.bankconnect__Payment_Type__c;
      this.achClass = p.bankconnect__ACH_Class__c;
      this.currencyCode = p.bankconnect__Currency_Code__c;
      this.startDate = p.bankconnect__Start_Date__c;
      this.endDate = p.bankconnect__End_Date__c;
      this.frequencyInterval = p.bankconnect__Frequency_Interval__c;
      this.lastStatusUpdate = p.bankconnect__Last_Status_Update__c;
      this.errorMessage = p.bankconnect__Error_Message__c;
      this.errorType = p.bankconnect__Error_Type__c;
      this.paymentReference = p.bankconnect__Payment_Reference__c;
    }
  }

  public class DocumentInsightInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Decimal averageDailyBalance;
    @AuraEnabled
    public Decimal averageMonthlyDeposits;
    @AuraEnabled
    public Decimal averageNsfs;
    @AuraEnabled
    public Decimal nsfs;
    @AuraEnabled
    public Decimal negativeWeekdays;
    @AuraEnabled
    public Decimal monthlyRevenue;
    @AuraEnabled
    public Decimal totalRevenue;
    @AuraEnabled
    public Decimal monthlyExpenses;
    @AuraEnabled
    public Decimal debtCoverageRatio;
    @AuraEnabled
    public Decimal totalStatements;
    @AuraEnabled
    public Decimal numberOfAccounts;

    public DocumentInsightInfo(bankconnect__PDF_Insight__c d) {
      this.id = d.Id;
      this.name = d.Name;
      this.status = d.bankconnect__Status__c;
      this.averageDailyBalance = d.bankconnect__Average_Daily_Balance__c;
      this.averageMonthlyDeposits = d.bankconnect__Average_Monthly_Deposits__c;
      this.averageNsfs = d.bankconnect__Average_NSFs__c;
      this.nsfs = d.bankconnect__NSFs__c;
      this.negativeWeekdays = d.bankconnect__Negative_Weekdays__c;
      this.monthlyRevenue = d.bankconnect__Monthly_Revenue__c;
      this.totalRevenue = d.bankconnect__Total_Revenue__c;
      this.monthlyExpenses = d.bankconnect__Monthly_Expenses__c;
      this.debtCoverageRatio = d.bankconnect__Debt_Coverage_Ratio__c;
      this.totalStatements = d.bankconnect__Total_Statements__c;
      this.numberOfAccounts = d.bankconnect__Number_Of_Accounts__c;
    }
  }

  public class TaskInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String subject;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String priority;
    @AuraEnabled
    public Date activityDate;
    @AuraEnabled
    public String description;
    @AuraEnabled
    public Datetime createdDate;
    @AuraEnabled
    public String ownerName;
    @AuraEnabled
    public String contactName;

    public TaskInfo(Task t) {
      this.id = t.Id;
      this.subject = t.Subject;
      this.status = t.Status;
      this.priority = t.Priority;
      this.activityDate = t.ActivityDate;
      this.description = t.Description;
      this.createdDate = t.CreatedDate;
      this.ownerName = t.Owner != null ? t.Owner.Name : null;
      this.contactName = t.Who != null ? t.Who.Name : null;
    }
  }

  public class EventInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String subject;
    @AuraEnabled
    public Datetime startDateTime;
    @AuraEnabled
    public Datetime endDateTime;
    @AuraEnabled
    public String description;
    @AuraEnabled
    public String ownerName;

    public EventInfo(Event e) {
      this.id = e.Id;
      this.subject = e.Subject;
      this.startDateTime = e.StartDateTime;
      this.endDateTime = e.EndDateTime;
      this.description = e.Description;
      this.ownerName = e.Owner != null ? e.Owner.Name : null;
    }
  }

  public class EmailInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String subject;
    @AuraEnabled
    public String fromAddress;
    @AuraEnabled
    public String toAddress;
    @AuraEnabled
    public Datetime messageDate;
    @AuraEnabled
    public Boolean incoming;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String snippet;

    public EmailInfo(EmailMessage e, Integer maxChars) {
      this.id = e.Id;
      this.subject = e.Subject;
      this.fromAddress = e.FromAddress;
      this.toAddress = e.ToAddress;
      this.messageDate = e.MessageDate;
      this.incoming = e.Incoming;
      this.status = e.Status;
      if (String.isNotBlank(e.TextBody)) {
        String body = e.TextBody.replaceAll('\\s+', ' ').trim();
        this.snippet = body.length() > maxChars
          ? body.substring(0, maxChars) + '…'
          : body;
      }
    }
  }

  /**
   * One note from either storage generation, flattened to a single shape so the
   * digest and the component do not have to care which one it came from.
   */
  public class NoteInfo {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String title;
    @AuraEnabled
    public String body;
    @AuraEnabled
    public String authorName;
    @AuraEnabled
    public Datetime createdDate;
    /** 'Enhanced' or 'Classic' — which object this came from. */
    @AuraEnabled
    public String source;

    public NoteInfo(ContentNote cn, Integer maxBodyChars) {
      this.id = cn.Id;
      this.title = cn.Title;
      this.authorName = cn.CreatedBy != null ? cn.CreatedBy.Name : null;
      this.createdDate = cn.CreatedDate;
      this.source = 'Enhanced';
      // ContentNote.Content is a Blob of HTML. Strip the markup before it can
      // reach a prompt — tags are noise to a model and to a reader.
      String raw = cn.Content != null ? cn.Content.toString() : null;
      this.body = clip(
        String.isBlank(raw) ? null : raw.stripHtmlTags(),
        maxBodyChars
      );
    }

    public NoteInfo(Note n, Integer maxBodyChars) {
      this.id = n.Id;
      this.title = n.Title;
      this.authorName = n.CreatedBy != null ? n.CreatedBy.Name : null;
      this.createdDate = n.CreatedDate;
      this.source = 'Classic';
      this.body = clip(n.Body, maxBodyChars);
    }

    private String clip(String value, Integer maxChars) {
      if (String.isBlank(value)) {
        return null;
      }
      String trimmed = value.trim();
      return trimmed.length() <= maxChars
        ? trimmed
        : trimmed.substring(0, maxChars) + '…';
    }
  }
}