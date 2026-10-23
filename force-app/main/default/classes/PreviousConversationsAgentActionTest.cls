@IsTest
private class PreviousConversationsAgentActionTest {
  private static Opportunity buildCase() {
    Account a = new Account(Name = 'Agent Action Test Co');
    insert a;
    insert new Contact(LastName = 'Tester', AccountId = a.Id, Phone = '555-867-5309');
    Opportunity opp = new Opportunity(
      Name = 'Agent Action Test Case',
      StageName = 'Prospecting',
      CloseDate = Date.today().addDays(30),
      AccountId = a.Id
    );
    insert opp;
    return opp;
  }

  private static PreviousConversationsAgentAction.Result run(Id recordId) {
    PreviousConversationsAgentAction.Request req = new PreviousConversationsAgentAction.Request();
    req.recordId = recordId;
    return PreviousConversationsAgentAction.getHistory(
      new List<PreviousConversationsAgentAction.Request>{ req }
    )[0];
  }

  @IsTest
  static void returnsTheHistoryAsTextForTheAgent() {
    Opportunity opp = buildCase();
    insert new Task(Subject = 'Called the client back', WhatId = opp.Id, Description = 'Wants to pause one month.');
    PreviousConversationsService.Entry call =
      PreviousConversationsService.stampCall(Date.newInstance(2026, 8, 25), '14:07');
    call.kind = 'Call';
    call.key = 'call-convoso-1';
    PreviousConversationsService.mockCalls = new List<PreviousConversationsService.Entry>{ call };

    Test.startTest();
    PreviousConversationsAgentAction.Result res = run(opp.Id);
    Test.stopTest();

    System.assertEquals(2, res.entryCount, 'the task and the call are both counted');
    System.assert(res.history.startsWith('Client case: Agent Action Test Case'), 'names the case first');
    System.assert(res.history.contains('Calls logged: 1'), 'says how many calls there were');
    System.assert(res.history.contains('no transcript'), 'tells the agent calls have no content');
    System.assert(res.history.contains('Called the client back'), 'the task is in the text');
    System.assert(res.history.contains('\n    '), 'details are indented under their entry');
  }

  @IsTest
  static void saysSoWhenThereIsNothing() {
    Opportunity opp = buildCase();
    PreviousConversationsService.mockCalls = new List<PreviousConversationsService.Entry>();

    PreviousConversationsAgentAction.Result res = run(opp.Id);

    System.assertEquals(0, res.entryCount, 'nothing found');
    System.assert(res.history.contains('No previous conversations were found'), 'an empty history is stated, not left blank');
  }

  @IsTest
  static void refusesANonOpportunityId() {
    Account a = new Account(Name = 'Wrong Object Co');
    insert a;

    PreviousConversationsAgentAction.Result res = run(a.Id);

    System.assert(res.history.contains('Open an Opportunity'), 'asks for a client case');
    System.assertEquals(0, res.entryCount, 'nothing is read');
  }

  @IsTest
  static void refusesACaseTheUserCannotRead() {
    PreviousConversationsAgentAction.Result res = run(Id.valueOf('006000000000000AAA'));
    System.assertEquals('You do not have access to this case.', res.history, 'an unreadable case is refused');
  }

  @IsTest
  static void handlesANullRequest() {
    List<PreviousConversationsAgentAction.Result> res = PreviousConversationsAgentAction.getHistory(
      new List<PreviousConversationsAgentAction.Request>{ null }
    );
    System.assert(res[0].history.contains('No client case was given'), 'a null request is answered, not thrown');
  }

  @IsTest
  static void capsALongHistory() {
    PreviousConversationsService.History h = new PreviousConversationsService.History();
    h.caseName = 'Busy Case';
    for (Integer i = 0; i < PreviousConversationsAgentAction.MAX_ENTRIES + 5; i++) {
      PreviousConversationsService.Entry e = new PreviousConversationsService.Entry();
      e.kind = 'Note';
      e.title = 'Note ' + i;
      e.detail = 'x'.repeat(50);
      h.entries.add(e);
    }

    String text = PreviousConversationsAgentAction.format(h);

    System.assert(text.length() <= PreviousConversationsAgentAction.MAX_CHARS + 200, 'stays inside the budget');
    System.assert(text.contains('older entries were left out'), 'says what was left out');
  }
}
