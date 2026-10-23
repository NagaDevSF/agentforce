import { createElement } from 'lwc';
import PreviousConversationsAI from 'c/previousConversationsAI';
import getHistory from '@salesforce/apex/PreviousConversationsController.getHistory';
import askAgent from '@salesforce/apex/PreviousConversationsController.askAgent';

jest.mock(
  '@salesforce/apex/PreviousConversationsController.getHistory',
  () => {
    const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true }
);
jest.mock(
  '@salesforce/apex/PreviousConversationsController.isAgentConfigured',
  () => {
    const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true }
);
jest.mock('@salesforce/apex/PreviousConversationsController.askAgent', () => ({ default: jest.fn() }), {
  virtual: true
});

const mockNavigate = jest.fn();
jest.mock('lightning/navigation', () => {
  const Navigate = Symbol('Navigate');
  const NavigationMixin = (Base) =>
    class extends Base {
      [Navigate](pageReference) {
        mockNavigate(pageReference);
      }
    };
  NavigationMixin.Navigate = Navigate;
  return { NavigationMixin };
});

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

const HISTORY = {
  caseName: 'Blue Ridge Freight',
  callCount: 1,
  notice: null,
  entries: [
    { key: 'call-convoso-1', kind: 'Call', dayLabel: 'Tuesday', dateLabel: 'Oct 21', timeLabel: '2:14 PM ET', title: 'Outbound', who: 'Case Manager' },
    { key: '02s000000000001AAA', kind: 'Email received', dayLabel: 'Monday', dateLabel: 'Oct 20', timeLabel: '9:40 AM ET', title: 'Creditor letter' },
    { key: '069000000000001AAA', kind: 'Note', dayLabel: 'Sunday', dateLabel: 'Oct 19', timeLabel: '4:02 PM ET', title: 'Spoke to client' },
    { key: '00T000000000001AAA', kind: 'Task', dayLabel: 'Sunday', dateLabel: 'Oct 19', timeLabel: '3:00 PM ET', title: 'Follow up' }
  ]
};

const CARD = {
  overallSummary: 'The client wants to pause one payment.',
  sentimentLabel: 'Negative',
  sentimentNote: 'Worried about a medical bill.',
  keyInsights: ['Client called twice this week'],
  customerConcerns: ['Can they skip October?'],
  nextActions: [{ action: 'Call the client back', priority: 'High', dueDate: '2026-11-03' }],
  nextKeyMeeting: { title: 'Review call', meetingDate: '2026-11-05', meetingTime: '10:00 AM' }
};

function mount(history = HISTORY) {
  const el = createElement('c-previous-conversations-ai', { is: PreviousConversationsAI });
  el.recordId = '006000000000001AAA';
  document.body.appendChild(el);
  getHistory.emit(history);
  return el;
}

const text = (el) => el.shadowRoot.textContent;
const generate = (el) =>
  Array.from(el.shadowRoot.querySelectorAll('button')).find((b) => /Generate|Regenerate/.test(b.textContent));

async function generateWith(el, reply) {
  askAgent.mockResolvedValue(reply);
  generate(el).click();
  await flush();
  await flush();
}

describe('c-previous-conversations-ai', () => {
  afterEach(() => {
    while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
    jest.clearAllMocks();
  });

  it('shows the client name and the counts without calling the AI', async () => {
    const el = mount();
    await flush();
    expect(el.shadowRoot.querySelector('.pc-name').textContent).toBe('Blue Ridge Freight');
    expect(el.shadowRoot.querySelector('.pc-avatar').textContent).toBe('BR');
    const nums = Array.from(el.shadowRoot.querySelectorAll('.pc-stat-num')).map((n) => n.textContent);
    expect(nums).toEqual(['1', '1', '1']);
    expect(text(el)).toContain('Generate AI Summary');
    expect(askAgent).not.toHaveBeenCalled();
  });

  it('has no conversation list, no ask box and no line under the call count', async () => {
    const el = mount();
    await flush();
    expect(text(el)).not.toContain('Recent Communications');
    expect(el.shadowRoot.querySelector('lightning-input')).toBeNull();
    expect(el.shadowRoot.querySelector('lightning-combobox')).toBeNull();
    expect(text(el)).not.toContain('Logged calls');
  });

  it('renders the AI Summary card after Generate', async () => {
    const el = mount();
    await flush();
    await generateWith(el, { summary: CARD, configured: true });
    expect(askAgent).toHaveBeenCalledWith({ recordId: '006000000000001AAA', agentId: 'xxxxxx', question: '' });
    expect(el.shadowRoot.querySelector('.pc-overall-text').textContent).toBe(CARD.overallSummary);
    expect(text(el)).toContain('Client called twice this week');
    expect(text(el)).toContain('Can they skip October?');
    expect(text(el)).toContain('High priority');
    expect(el.shadowRoot.querySelector('.pc-due').textContent).toBe('Nov 3');
    expect(el.shadowRoot.querySelector('.pc-meeting-title').textContent).toBe('Review call');
    expect(text(el)).toContain('Last updated:');
    expect(text(el)).toContain('Regenerate');
  });

  it.each([
    ['Positive', 'pc-text-green', 'pc-tone-green'],
    ['Neutral', 'pc-text-blue', 'pc-tone-blue'],
    ['Negative', 'pc-text-red', 'pc-tone-red'],
    ['Unknown', 'pc-text-gray', 'pc-tone-gray']
  ])('colors %s sentiment', async (label, textClass, iconClass) => {
    const el = mount();
    await flush();
    await generateWith(el, { summary: { ...CARD, sentimentLabel: label } });
    const shown = el.shadowRoot.querySelector('.pc-sentiment-label');
    expect(shown.textContent).toBe(label);
    expect(shown.className).toContain(textClass);
    expect(el.shadowRoot.querySelector('.pc-sentiment .pc-round-icon').className).toContain(iconClass);
  });

  it('shows the raw reply as the overall summary when the card could not be parsed', async () => {
    const el = mount();
    await flush();
    await generateWith(el, { text: 'The client is waiting on a date.' });
    expect(el.shadowRoot.querySelector('.pc-overall-text').textContent).toBe('The client is waiting on a date.');
  });

  it('drops a reply that arrives after the case changed', async () => {
    let resolve;
    askAgent.mockImplementation(() => new Promise((r) => { resolve = r; }));
    const el = mount();
    await flush();
    generate(el).click();
    el.recordId = '006000000000002AAA';
    getHistory.emit({ ...HISTORY, caseName: 'Other Client' });
    resolve({ summary: CARD });
    await flush();
    await flush();
    expect(el.shadowRoot.querySelector('.pc-overall-text')).toBeNull();
    expect(el.shadowRoot.querySelector('.pc-name').textContent).toBe('Other Client');
  });

  it('says so and disables Generate when the case has no history', async () => {
    const el = mount({ ...HISTORY, entries: [] });
    await flush();
    expect(text(el)).toContain('Nothing has been recorded on this case yet');
    expect(generate(el).disabled).toBe(true);
  });

  it('shows the notice when the AI is unavailable', async () => {
    const el = mount();
    await flush();
    await generateWith(el, { notice: 'The AI is unavailable right now.' });
    expect(el.shadowRoot.querySelector('.pc-notice').textContent).toContain('unavailable');
  });

  it('opens the Opportunity from View record', async () => {
    const el = mount();
    await flush();
    Array.from(el.shadowRoot.querySelectorAll('button')).find((b) => b.textContent.includes('View record')).click();
    expect(mockNavigate.mock.calls[0][0].attributes.recordId).toBe('006000000000001AAA');
  });
});
