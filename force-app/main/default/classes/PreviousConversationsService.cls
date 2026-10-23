/**
 * One chronological conversation history for a case, from every channel a
 * human actually used: email, tasks, calendar events, notes, case comments,
 * and the calls Convoso logged into Data 360.
 *
 * WHAT THIS IS FOR
 * ----------------
 * A case manager picking a case back up asks one question first — "what has
 * already been said to this client?" — and today the answer is spread across
 * six related lists and a Data Cloud object with no relationship to the record
 * at all. This gathers them into one ordered list.
 *
 * CALLS CARRY NO CONTENT, AND THAT IS NOT A BUG
 * ---------------------------------------------
 * Convoso_Call_Log_V2__dlm stores when a call happened, who took it, how long
 * it ran and where the audio lives. It does NOT store a transcript, so nothing
 * here can say what was discussed on a call. Call entries report the DAY, DATE
 * and TIME only. Turning recordings into text is a separate piece of work
 * (Einstein Conversation Insights or a speech-to-text vendor) and deliberately
 * out of scope.
 *
 * WHY CALL TIMES ARE LABELLED ET AND NOT CONVERTED
 * ------------------------------------------------
 * The Convoso feed lands call_date__c / call_time__c already in Eastern local
 * time. CallRecordingsData360Controller — live in production — formats them by
 * labelling, never converting, and this follows it deliberately. The DMO also
 * offers call_datetime__c, which LOOKS like the better field and is a trap:
 * reading it as an instant re-interprets an already-local wall-clock time and
 * shifts every call by the UTC offset. Display comes from the raw strings; the
 * constructed Datetime is used for ORDERING only.
 *
 * SCOPE IS THE CLIENT, NOT THE OPPORTUNITY
 * ----------------------------------------
 * The timeline covers the ACCOUNT and everything reachable from it: every
 * Opportunity on that account, their Cases and CreditorOpportunity__c rows, the
 * Negotiation__c records hanging off those Cases, and the account's Contacts.
 *
 * An earlier cut anchored on the one Opportunity and treated a client's other
 * enrolments as somebody else's conversation. A client does not experience it
 * that way, and a case manager asking "what has already been said to this
 * client" is not asking about one enrolment. 178 production accounts hold more
 * than one Opportunity, carrying 202 siblings, so this changes what is shown on
 * about 1 percent of accounts and leaves the rest identical.
 *
 * Widening the scope does NOT widen what any one user can see: every query here
 * runs WITH USER_MODE, so a sibling the running user has no access to never
 * enters the scope in the first place.
 *
 * SECURITY
 * --------
 * Data 360 DMOs carry no CRM record-level access control. So the CRM record is
 * authorised in user mode FIRST, phone numbers are derived from rows the user
 * can actually see, and only then is the DMO queried by those phones. Every
 * SOQL query here runs WITH USER_MODE. Text that a human wrote is passed
 * through CaseManagerAIDigestService.neutralise() at the point of entry, so a
 * client who types prompt structure into an email cannot forge it downstream.
 */
public with sharing class PreviousConversationsService {
  /** Per-source row cap, so one noisy case cannot blow heap or the timeline. */
  private static final Integer ROW_CAP = 200;

  /** Longest single detail line kept. Matches the summariser's item budget. */
  private static final Integer MAX_DETAIL_CHARS = 800;

  /** Data 360 plumbing, same space and DMO the live call component uses. */
  private static final String DATA_SPACE = 'default';
  private static final String WORKLOAD_NAME = 'previous-conversations-lwc';
  private static final String CALL_DMO = 'Convoso_Call_Log_V2__dlm';
  private static final Integer CALL_ROW_CAP = 100;
  private static final Integer MAX_PHONE_VALUES = 500;

  /** Relation rows scanned to find email that names one of this case's contacts. */
  private static final Integer EMAIL_RELATION_CAP = 500;

  private static final Map<Integer, String> DAY_NAMES = new Map<Integer, String>{
    0 => 'Sunday', 1 => 'Monday', 2 => 'Tuesday', 3 => 'Wednesday',
    4 => 'Thursday', 5 => 'Friday', 6 => 'Saturday'
  };
  private static final List<String> MONTHS = new List<String>{
    'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
  };

  /**
   * The timezone every timestamp on this card renders in.
   *
   * A constant, not a query, and that is the point. Organization is NOT
   * readable by the Case Manager profile — [SELECT TimeZoneSidKey FROM
   * Organization] throws "sObject type 'Organization' is not supported" under
   * runAs, which would take the whole timeline down for precisely the users
   * this component exists for. It also saves a query.
   *
   * America/New_York is both the organisation's timezone and the zone the
   * Convoso feed emits call times in, so one constant serves both halves of the
   * card and the "ET" suffix on call rows stays truthful. If the business ever
   * moves timezone, this is the one line to change.
   *
   * Rendering in org time rather than the viewer's is deliberate: 15 of 133
   * active users in production sit outside Eastern, and under user-local
   * formatting their Salesforce rows read in their own zone while call rows
   * carried a hard-coded ET label — two halves of one card disagreeing, with
   * the interleaved ordering drifting to match.
   */
  private static final String DISPLAY_TIMEZONE = 'America/New_York';

  private static TimeZone displayZone;

  private static TimeZone displayZone() {
    if (displayZone == null) {
      displayZone = TimeZone.getTimeZone(DISPLAY_TIMEZONE);
    }
    return displayZone;
  }

  /** Test seam: bypasses the Data 360 callout and returns canned call rows. */
  @TestVisible
  private static List<Entry> mockCalls;

  /**
   * One thing that happened, from any channel.
   *
   * `occurred` exists to sort by and is never rendered — the three label fields
   * are what the component shows, because "Tuesday" and "2:14 PM ET" are what a
   * case manager actually reads.
   */
  public class Entry implements Comparable {
    @AuraEnabled public String key;
    @AuraEnabled public String kind;
    @AuraEnabled public String dayLabel;
    @AuraEnabled public String dateLabel;
    @AuraEnabled public String timeLabel;
    @AuraEnabled public String title;
    @AuraEnabled public String detail;
    @AuraEnabled public String who;
    @AuraEnabled public String link;
    /** Calls only: true when the client did not pick up (see callEntry). */
    @AuraEnabled public Boolean unanswered = false;
    /** Calls only: true for a call our team made to the client. */
    @AuraEnabled public Boolean outbound = false;
    public Datetime occurred;

    /** Newest first. Undated rows sink rather than jumping the list. */
    public Integer compareTo(Object other) {
      Datetime mine = this.occurred;
      Datetime theirs = ((Entry) other).occurred;
      if (mine == theirs) { return 0; }
      if (mine == null) { return 1; }
      if (theirs == null) { return -1; }
      return mine > theirs ? -1 : 1;
    }
  }

  /** What the component renders: the timeline plus what it could not reach. */
  public class History {
    @AuraEnabled public List<Entry> entries = new List<Entry>();
    @AuraEnabled public String caseName;
    @AuraEnabled public Integer callCount = 0;
    @AuraEnabled public String notice;
  }

  /**
   * The whole conversation history for one Opportunity.
   *
   * @param oppId the case. Authorised in user mode before anything else runs.
   */
  public static History forCase(Id oppId) {
    History out = new History();
    if (oppId == null) {
      return out;
    }

    List<Opportunity> opps = [
      SELECT Id, Name, AccountId
      FROM Opportunity
      WHERE Id = :oppId
      WITH USER_MODE
      LIMIT 1
    ];
    if (opps.isEmpty()) {
      throw new AuraHandledException('You do not have access to this case.');
    }
    Opportunity opp = opps[0];
    out.caseName = opp.Name;

    Scope scope = buildScope(opp);

    addEmails(out, scope);
    addTasks(out, scope);
    addEvents(out, scope);
    addNotes(out, scope);
    addContentNotes(out, scope);
    addCaseComments(out, scope);
    addCalls(out, scope);

    out.entries.sort();
    return out;
  }

  /**
   * Everything a conversation on this case could hang off.
   *
   * Salesforce lets a human attach the same conversation to any of four
   * records, and they use all four: an email logged on the Opportunity, a task
   * on the Case, a call note on the Account, a meeting on the Contact. Anchoring
   * only on the Opportunity — which is what the first cut of this class did —
   * captured about half of it. Measured against production: 3,672 tasks sit on
   * Opportunities, 2,668 on Cases, 441 on Accounts, and 706 events hang off a
   * Contact with no WhatId at all.
   *
   * This mirrors CaseManagerAIService, which scopes to {opportunity, account}
   * and pulls Cases by Opportunity__c OR AccountId, and widens it by the Case
   * and Contact ids — the sets are gathered anyway, so the extra reach costs
   * wider IN clauses rather than more queries.
   *
   * Lead activity is deliberately NOT reachable here. 92,740 tasks in
   * production hang off a Lead with no WhatId; that is pre-conversion work and
   * belongs to nobody's case.
   */
  private class Scope {
    Id oppId;
    Id accountId;
    /**
     * Every Opportunity on the account, this one included.
     *
     * The first cut anchored on oppId alone and treated a client's other
     * opportunities as out of scope. That is the wrong default for this
     * component: the question a case manager asks is "what has already been
     * said to this CLIENT", and a client does not experience their second
     * enrolment as a separate conversation. 178 production accounts carry more
     * than one, for 202 siblings in total, so this widens the timeline on
     * roughly 1 percent of accounts and changes nothing on the rest.
     */
    Set<Id> opportunityIds = new Set<Id>();
    Set<Id> contactIds = new Set<Id>();
    Set<String> phones = new Set<String>();
    Map<Id, Case> caseById = new Map<Id, Case>();
    /** Anything that can be a WhatId or RelatedToId. */
    Set<Id> relatedIds = new Set<Id>();
    /** Anything that can carry a Note or a file. */
    Set<Id> linkedIds = new Set<Id>();
    /** Emails that name one of this case's contacts, found via EmailMessageRelation. */
    Set<Id> emailIds = new Set<Id>();
  }

  private static Scope buildScope(Opportunity opp) {
    Scope sc = new Scope();
    sc.oppId = opp.Id;
    sc.accountId = opp.AccountId;

    // The account's whole book, gathered first because the Case and
    // CreditorOpportunity queries below are scoped by it.
    //
    // WITH USER_MODE means a sibling the running user cannot see never enters
    // the scope, so widening here cannot widen what any one user is shown.
    sc.opportunityIds.add(sc.oppId);
    if (sc.accountId != null) {
      for (Opportunity sibling : [
        SELECT Id
        FROM Opportunity
        WHERE AccountId = :sc.accountId
        WITH USER_MODE
        LIMIT :ROW_CAP
      ]) {
        sc.opportunityIds.add(sibling.Id);
      }
    }

    // One Contact query serves both the timeline scope and the call phone match.
    if (sc.accountId != null) {
      for (Contact c : [
        SELECT Id, Phone, MobilePhone
        FROM Contact
        WHERE AccountId = :sc.accountId
        WITH USER_MODE
        LIMIT :ROW_CAP
      ]) {
        sc.contactIds.add(c.Id);
        addPhoneVariants(sc.phones, c.Phone);
        addPhoneVariants(sc.phones, c.MobilePhone);
      }
    }

    // Cases hanging off ANY of the account's opportunities, plus the account's
    // own. The AccountId leg already caught most of these; the IN clause also
    // catches a Case whose AccountId was never populated.
    Set<Id> scopedOppIds = sc.opportunityIds;
    sc.caseById = new Map<Id, Case>([
      SELECT Id, CaseNumber, Subject
      FROM Case
      WHERE Opportunity__c IN :scopedOppIds OR AccountId = :sc.accountId
      WITH USER_MODE
      LIMIT :ROW_CAP
    ]);

    sc.relatedIds.addAll(sc.opportunityIds);
    sc.linkedIds.addAll(sc.opportunityIds);
    if (sc.accountId != null) {
      sc.relatedIds.add(sc.accountId);
      sc.linkedIds.add(sc.accountId);
    }
    sc.relatedIds.addAll(sc.caseById.keySet());
    sc.linkedIds.addAll(sc.caseById.keySet());
    sc.linkedIds.addAll(sc.contactIds);

    // DCG's own domain objects carry activity too. Measured in production:
    // 2 tasks and 2 emails on Negotiation__c, 1 event on CreditorOpportunity__c.
    // Tiny today, but settlement work lives on these records and "all related
    // objects" is only true if they are here. Two queries against a limit of
    // 100, and the alternative is a caveat that grows quietly.
    for (CreditorOpportunity__c co : [
      SELECT Id
      FROM CreditorOpportunity__c
      WHERE Opportunity__c IN :scopedOppIds
      WITH USER_MODE
      LIMIT :ROW_CAP
    ]) {
      sc.relatedIds.add(co.Id);
      sc.linkedIds.add(co.Id);
    }

    // Negotiation has no path to the Opportunity — it hangs off the Case.
    if (!sc.caseById.isEmpty()) {
      Set<Id> negCaseIds = sc.caseById.keySet();
      for (Negotiation__c n : [
        SELECT Id
        FROM Negotiation__c
        WHERE Case__c IN :negCaseIds
        WITH USER_MODE
        LIMIT :ROW_CAP
      ]) {
        sc.relatedIds.add(n.Id);
        sc.linkedIds.add(n.Id);
      }
    }

    // The backstop for email that carries no parent.
    //
    // 33,001 of 40,360 EmailMessages in production have neither RelatedToId nor
    // ParentId, which looks alarming and mostly is not: 13,427 of those are
    // Lead email, which belongs to nobody's case. Only 128 orphan emails carry
    // a Contact relation. So this leg recovers roughly 128 messages org-wide,
    // not thousands — measured, after an earlier note here claimed otherwise.
    //
    // Kept anyway. Those 128 are real client email that would otherwise vanish
    // silently, it costs one query, and it is the join that stays correct if
    // anyone ever logs email against a contact without relating it to a record.
    //
    // Contact relations only, deliberately. Relating on User would match the
    // case manager rather than the client — there are 41,966 User ToAddress
    // relations against 5,761 Contact ones — and would pour that manager's
    // entire mailbox into every case they open.
    if (!sc.contactIds.isEmpty()) {
      Set<Id> relationIds = sc.contactIds;
      for (EmailMessageRelation emr : [
        SELECT EmailMessageId
        FROM EmailMessageRelation
        WHERE RelationId IN :relationIds
        WITH USER_MODE
        LIMIT :EMAIL_RELATION_CAP
      ]) {
        sc.emailIds.add(emr.EmailMessageId);
      }
    }

    return sc;
  }

  // ───────────────────────── Salesforce channels ─────────────────────────

  private static void addEmails(History out, Scope sc) {
    Set<Id> relatedIds = sc.relatedIds;
    Set<Id> caseIds = sc.caseById.keySet();
    Set<Id> emailIds = sc.emailIds;
    for (EmailMessage em : [
      SELECT Id, Subject, TextBody, MessageDate, Incoming, FromName
      FROM EmailMessage
      WHERE Id IN :emailIds
         OR RelatedToId IN :relatedIds
         OR ParentId IN :caseIds
      WITH USER_MODE
      ORDER BY MessageDate DESC
      LIMIT :ROW_CAP
    ]) {
      Entry e = stamp(em.MessageDate);
      e.key = em.Id;
      e.kind = em.Incoming == true ? 'Email received' : 'Email sent';
      e.title = clean(em.Subject);
      e.detail = clean(em.TextBody);
      e.who = clean(em.FromName);
      out.entries.add(e);
    }
  }

  /**
   * Every Task type — calls logged in CRM, emails, to-dos, anything custom.
   *
   * WhoId is matched as well as WhatId because a task logged against the client
   * contact with no WhatId is still a conversation with that client.
   */
  private static void addTasks(History out, Scope sc) {
    Set<Id> relatedIds = sc.relatedIds;
    Set<Id> contactIds = sc.contactIds;
    for (Task t : [
      SELECT Id, Subject, Description, CreatedDate, ActivityDate, Status,
             TaskSubtype, Owner.Name
      FROM Task
      WHERE WhatId IN :relatedIds OR WhoId IN :contactIds
      WITH USER_MODE
      ORDER BY CreatedDate DESC
      LIMIT :ROW_CAP
    ]) {
      Entry e = stamp(t.CreatedDate);
      e.key = t.Id;
      e.kind = String.isBlank(t.TaskSubtype) ? 'Task' : 'Task · ' + t.TaskSubtype;
      e.title = clean(t.Subject);
      e.detail = clean(t.Description);
      e.who = t.Owner == null ? null : t.Owner.Name;
      out.entries.add(e);
    }
  }

  private static void addEvents(History out, Scope sc) {
    Set<Id> relatedIds = sc.relatedIds;
    Set<Id> contactIds = sc.contactIds;
    for (Event ev : [
      SELECT Id, Subject, Description, StartDateTime, Owner.Name
      FROM Event
      WHERE WhatId IN :relatedIds OR WhoId IN :contactIds
      WITH USER_MODE
      ORDER BY StartDateTime DESC
      LIMIT :ROW_CAP
    ]) {
      Entry e = stamp(ev.StartDateTime);
      e.key = ev.Id;
      e.kind = 'Calendar event';
      e.title = clean(ev.Subject);
      e.detail = clean(ev.Description);
      e.who = ev.Owner == null ? null : ev.Owner.Name;
      out.entries.add(e);
    }
  }

  private static void addNotes(History out, Scope sc) {
    Set<Id> linkedIds = sc.linkedIds;
    for (Note n : [
      SELECT Id, Title, Body, CreatedDate, Owner.Name
      FROM Note
      WHERE ParentId IN :linkedIds
      WITH USER_MODE
      ORDER BY CreatedDate DESC
      LIMIT :ROW_CAP
    ]) {
      Entry e = stamp(n.CreatedDate);
      e.key = n.Id;
      e.kind = 'Note';
      e.title = clean(n.Title);
      e.detail = clean(n.Body);
      e.who = n.Owner == null ? null : n.Owner.Name;
      out.entries.add(e);
    }
  }

  /**
   * ContentNote reaches the case through ContentDocumentLink, not a parent id,
   * so it takes two queries. TextPreview rather than Content: Content is
   * base64 HTML and would arrive as noise.
   */
  private static void addContentNotes(History out, Scope sc) {
    Set<Id> linkedIds = sc.linkedIds;
    Set<Id> docIds = new Set<Id>();
    for (ContentDocumentLink cdl : [
      SELECT ContentDocumentId
      FROM ContentDocumentLink
      WHERE LinkedEntityId IN :linkedIds
      WITH USER_MODE
      LIMIT :ROW_CAP
    ]) {
      docIds.add(cdl.ContentDocumentId);
    }
    if (docIds.isEmpty()) {
      return;
    }
    for (ContentNote cn : [
      SELECT Id, Title, TextPreview, CreatedDate, CreatedBy.Name
      FROM ContentNote
      WHERE Id IN :docIds
      WITH USER_MODE
      ORDER BY CreatedDate DESC
      LIMIT :ROW_CAP
    ]) {
      Entry e = stamp(cn.CreatedDate);
      e.key = cn.Id;
      e.kind = 'Note';
      e.title = clean(cn.Title);
      e.detail = clean(cn.TextPreview);
      e.who = cn.CreatedBy == null ? null : cn.CreatedBy.Name;
      out.entries.add(e);
    }
  }

  /** Comments on every Case reachable from this case or its account. */
  private static void addCaseComments(History out, Scope sc) {
    if (sc.caseById.isEmpty()) {
      return;
    }
    Set<Id> caseIds = sc.caseById.keySet();
    for (CaseComment cc : [
      SELECT Id, ParentId, CommentBody, CreatedDate, CreatedBy.Name
      FROM CaseComment
      WHERE ParentId IN :caseIds
      WITH USER_MODE
      ORDER BY CreatedDate DESC
      LIMIT :ROW_CAP
    ]) {
      Case parent = sc.caseById.get(cc.ParentId);
      Entry e = stamp(cc.CreatedDate);
      e.key = cc.Id;
      e.kind = 'Case comment';
      e.title = parent == null
        ? 'Case comment'
        : 'Case ' + parent.CaseNumber + (String.isBlank(parent.Subject) ? '' : ' — ' + clean(parent.Subject));
      e.detail = clean(cc.CommentBody);
      e.who = cc.CreatedBy == null ? null : cc.CreatedBy.Name;
      out.entries.add(e);
    }
  }

  // ───────────────────────── Data 360 calls ─────────────────────────

  /**
   * Calls for every phone number on the account's contacts.
   *
   * The DMO has no relationship to the Opportunity — phone number is the only
   * join there is — so the account is read in user mode first and the numbers
   * come from contacts the running user can see.
   *
   * Failure is silent and non-fatal: Data Cloud being unreachable must not take
   * the Salesforce half of the timeline down with it.
   */
  private static void addCalls(History out, Scope sc) {
    if (mockCalls != null) {
      out.entries.addAll(mockCalls);
      out.callCount = mockCalls.size();
      return;
    }
    Set<String> phones = sc.phones;
    if (phones.isEmpty() || phones.size() > MAX_PHONE_VALUES) {
      if (!phones.isEmpty()) {
        out.notice = 'Too many phone numbers on this account to match calls reliably.';
      }
      return;
    }

    try {
      List<String> placeholders = new List<String>();
      List<ConnectApi.QuerySqlParameterItem> params =
        new List<ConnectApi.QuerySqlParameterItem>();
      Integer i = 0;
      for (String phone : phones) {
        String name = 'phone' + i;
        placeholders.add(':' + name);
        ConnectApi.QuerySqlParameterItem p = new ConnectApi.QuerySqlParameterItem();
        p.name = name;
        p.type = ConnectApi.TypeEnum.VARCHAR;
        p.value = phone;
        params.add(p);
        i++;
      }

      // Deduplicated the same way the live component does: the ingestion stream
      // replays rows, and a replayed call is not a second conversation.
      String sql =
        'SELECT call_id__c, call_date__c, call_time__c, agent_name__c, ' +
        'recording_url__c, source__c, status_name__c, ' +
        'CAST(duration_seconds__c AS VARCHAR) AS duration_text FROM (' +
          'SELECT call_id__c, call_date__c, call_time__c, agent_name__c, ' +
          'recording_url__c, source__c, status_name__c, duration_seconds__c, ' +
          'ROW_NUMBER() OVER (' +
            'PARTITION BY LOWER(TRIM(source__c)), TRIM(call_id__c) ' +
            'ORDER BY call_date__c DESC NULLS LAST, call_time__c DESC NULLS LAST' +
          ') AS rn FROM ' + CALL_DMO + ' ' +
          'WHERE phone_number__c IN (' + String.join(placeholders, ', ') + ') ' +
            'AND call_id__c IS NOT NULL AND source__c IS NOT NULL' +
        ') AS d WHERE rn = 1 ' +
        'ORDER BY call_date__c DESC NULLS LAST, call_time__c DESC NULLS LAST ' +
        'LIMIT ' + CALL_ROW_CAP;

      ConnectApi.QuerySqlInput input = new ConnectApi.QuerySqlInput();
      input.sql = sql;
      input.sqlParameters = params;
      input.rowLimit = Long.valueOf(String.valueOf(CALL_ROW_CAP));

      sfsqlquery.SqlRowIterator rows = sfsqlquery.SqlStatement.create(input, DATA_SPACE)
        .withWorkloadName(WORKLOAD_NAME)
        .execute();

      for (sfsqlquery.Row row : rows) {
        Entry e = callEntry(
          row.getString('source__c'),
          row.getString('call_id__c'),
          row.getDate('call_date__c'),
          row.getString('call_time__c'),
          row.getString('agent_name__c'),
          row.getString('recording_url__c'),
          row.getString('status_name__c'),
          parseSeconds(row.getString('duration_text'))
        );
        if (e == null) {
          continue;
        }
        out.entries.add(e);
        out.callCount++;
      }
    } catch (ConnectApi.ConnectApiException dataCloudEx) {
      // Genuine availability: Data Cloud down, DMO renamed, no Data 360 licence.
      out.notice = 'Call history is temporarily unavailable.';
      System.debug(LoggingLevel.WARN, 'Call history unavailable: ' + dataCloudEx.getMessage());
    } catch (CalloutException calloutEx) {
      out.notice = 'Call history is temporarily unavailable.';
      System.debug(LoggingLevel.WARN, 'Call history callout failed: ' + calloutEx.getMessage());
    } catch (Exception unexpected) {
      // NOT an availability problem — a defect in this method. The case manager
      // still gets the Salesforce half of the timeline, but this is logged at
      // ERROR with its type so it cannot masquerade as expected degradation
      // forever, which is exactly what one blanket WARN catch allowed.
      out.notice = 'Call history is temporarily unavailable.';
      System.debug(
        LoggingLevel.ERROR,
        'Unexpected call-history failure: ' +
          unexpected.getTypeName() + ': ' + unexpected.getMessage()
      );
    }
  }

  /**
   * One DMO row as a timeline entry.
   *
   * Split out of the iterator loop on purpose: a test context cannot reach Data
   * Cloud, so mapping logic living inside that loop could never be exercised.
   * Here it takes primitives and is pinned directly.
   *
   * @return null for a row with no date — an undated call is not a fact about when.
   */
  @TestVisible
  private static Entry callEntry(
    String source,
    String callId,
    Date callDate,
    String callTime,
    String agentName,
    String recordingUrl
  ) {
    return callEntry(source, callId, callDate, callTime, agentName, recordingUrl, null, null);
  }

  /**
   * A call the client did not pick up, decided from what the dialer recorded.
   *
   * Talkdesk and 8x8 record only the direction (inbound / outbound) and the
   * length, so an OUTBOUND call shorter than 30 seconds counts as not answered
   * (a ring-out or a voicemail) - the user's rule, 23 Oct 2026. Convoso records
   * a real outcome, so its no-contact outcomes count whatever the length.
   * An inbound call is never "not answered by the client": they made it.
   */
  @TestVisible
  private static final Integer UNANSWERED_MAX_SECONDS = 30;

  @TestVisible
  private static final Set<String> NO_CONTACT_OUTCOMES = new Set<String>{
    'not available', 'answering machine', 'line is busy', 'busy', 'no answer',
    'voicemail', 'left voicemail', 'hang up'
  };

  @TestVisible
  private static Entry callEntry(
    String source,
    String callId,
    Date callDate,
    String callTime,
    String agentName,
    String recordingUrl,
    String status,
    Integer durationSeconds
  ) {
    if (callDate == null) {
      return null;
    }
    Entry e = stampCall(callDate, callTime);
    e.key = 'call-' + source + '-' + callId;
    e.kind = 'Call';
    e.who = clean(agentName);
    e.link = isHttpsUrl(recordingUrl) ? recordingUrl.trim() : null;

    String outcome = String.isBlank(status) ? '' : status.trim().toLowerCase();
    Boolean isInbound = outcome == 'inbound';
    e.outbound = !isInbound;
    Boolean shortOutbound = outcome == 'outbound' && durationSeconds != null &&
      durationSeconds < UNANSWERED_MAX_SECONDS;
    e.unanswered = !isInbound && (NO_CONTACT_OUTCOMES.contains(outcome) || shortOutbound);

    List<String> parts = new List<String>();
    parts.add(isInbound ? 'Inbound' : 'Outbound');
    if (durationSeconds != null) {
      parts.add(formatSeconds(durationSeconds));
    }
    if (String.isNotBlank(status) && outcome != 'inbound' && outcome != 'outbound') {
      parts.add(clean(status));
    }
    if (e.unanswered) {
      parts.add('not answered');
    }
    e.title = 'Call: ' + String.join(parts, ', ');
    return e;
  }

  /** "125" or "125.0" from the DMO as whole seconds; anything else is unknown. */
  @TestVisible
  private static Integer parseSeconds(String raw) {
    if (String.isBlank(raw)) {
      return null;
    }
    try {
      return Decimal.valueOf(raw.trim()).intValue();
    } catch (Exception e) {
      return null;
    }
  }

  private static String formatSeconds(Integer seconds) {
    Integer m = seconds / 60;
    Integer sec = Math.mod(seconds, 60);
    return m + ':' + (sec < 10 ? '0' : '') + sec;
  }

  /** Raw, digits, last ten, and both 1-prefixed forms. Mirrors the live component. */
  @TestVisible
  private static void addPhoneVariants(Set<String> phones, String phone) {
    if (String.isBlank(phone)) {
      return;
    }
    String raw = phone.trim();
    String digits = raw.replaceAll('[^0-9]', '');
    phones.add(raw);
    if (String.isNotBlank(digits)) {
      phones.add(digits);
    }
    if (digits.length() >= 10) {
      String ten = digits.right(10);
      phones.add(ten);
      phones.add('1' + ten);
      phones.add('+1' + ten);
    }
  }

  /** Only real links reach the UI. Providers also emit 8x8:// style placeholders. */
  private static Boolean isHttpsUrl(String url) {
    return String.isNotBlank(url) && url.trim().toLowerCase().startsWith('https://');
  }

  // ───────────────────────── Stamps ─────────────────────────

  /** Day, date and time for a real Salesforce Datetime, in the user's zone. */
  private static Entry stamp(Datetime occurredAt) {
    Entry e = new Entry();
    e.occurred = occurredAt;
    if (occurredAt == null) {
      e.dayLabel = '';
      e.dateLabel = 'Undated';
      e.timeLabel = '';
      return e;
    }
    String tzId = DISPLAY_TIMEZONE;
    e.dayLabel = occurredAt.format('EEEE', tzId);
    e.dateLabel = occurredAt.format('d MMM yyyy', tzId);
    e.timeLabel = occurredAt.format('h:mm a', tzId);
    return e;
  }

  /**
   * Day, date and time for a Convoso call.
   *
   * The strings arrive already in Eastern, so they are labelled and never
   * converted — see the class header. `occurred` is built from the same values
   * purely so calls interleave with everything else in the sort; it is not
   * rendered, and it is only exact when the running user is on Eastern.
   */
  @TestVisible
  private static Entry stampCall(Date callDate, String callTime) {
    Entry e = new Entry();
    e.dayLabel = DAY_NAMES.get(Math.mod(dayNumber(callDate), 7));
    e.dateLabel = callDate.day() + ' ' + MONTHS[callDate.month() - 1] + ' ' + callDate.year();

    Integer hour24 = -1;
    Integer minute = 0;
    if (String.isNotBlank(callTime)) {
      List<String> parts = callTime.trim().split(':');
      if (parts.size() >= 2) {
        try {
          hour24 = Integer.valueOf(parts[0]);
          minute = Integer.valueOf(parts[1]);
        } catch (TypeException ignored) {
          hour24 = -1;
        }
      }
    }
    if (hour24 < 0 || hour24 > 23 || minute < 0 || minute > 59) {
      e.timeLabel = 'Time not recorded';
      e.occurred = atOrgTime(callDate, 0, 0);
      return e;
    }

    Integer display = Math.mod(hour24, 12);
    if (display == 0) {
      display = 12;
    }
    String mm = minute < 10 ? '0' + minute : String.valueOf(minute);
    e.timeLabel = display + ':' + mm + ' ' + (hour24 >= 12 ? 'PM' : 'AM') + ' ET';
    e.occurred = atOrgTime(callDate, hour24, minute);
    return e;
  }

  /**
   * A Convoso wall-clock reading turned into a real instant, in ORG time.
   *
   * Datetime.newInstance() would read these numbers in the RUNNING USER's zone,
   * so the same call sorted differently for a Los Angeles manager than for an
   * Eastern one. Building the instant in GMT and then backing out the org's
   * offset for that date pins it to org time and keeps DST honest, because
   * getOffset() is evaluated against the date in question rather than today.
   *
   * The ET label above stays correct while the org runs on America/New_York,
   * which is what the Convoso feed emits. If the org timezone ever moves, this
   * pair of lines is what needs revisiting.
   */
  private static Datetime atOrgTime(Date d, Integer hour24, Integer minute) {
    Datetime asIfGmt = Datetime.newInstanceGmt(
      d, Time.newInstance(hour24, minute, 0, 0)
    );
    return asIfGmt.addSeconds(-displayZone().getOffset(asIfGmt) / 1000);
  }

  /** Day-of-week index for a Date, without leaning on locale formatting. */
  private static Integer dayNumber(Date d) {
    return Date.newInstance(1900, 1, 7).daysBetween(d);
  }

  /**
   * Defang and bound one piece of human-written text.
   *
   * neutralise() is reused from the digest rather than reimplemented: it is the
   * control that stops a client's email forging prompt structure, and two
   * copies of a security control drift apart.
   */
  private static String clean(String raw) {
    if (String.isBlank(raw)) {
      return null;
    }
    // MAX_DETAIL_CHARS is passed in rather than checked afterwards. The
    // one-argument neutralise() abbreviates at 200 for the digest's bullets,
    // which silently cut every conversation body here to a quarter of its
    // budget and made the old length check below unreachable.
    String safe = CaseManagerAIDigestService.neutralise(raw, MAX_DETAIL_CHARS).trim();
    return safe.replaceAll('\\s+', ' ');
  }
}