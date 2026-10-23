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
    { key: 'call-convoso-1', kind: 'Call', dayLabel: 'Tuesday', dateLabel: 'Oct 21', timeLabel: '2:14 PM ET', title: 'Outbound', who: 'Case Manager', link: 'https://rec.example.com/1' },
    { key: '02s000000000001AAA', kind: 'Email received', dayLabel: 'Monday', dateLabel: 'Oct 20', timeLabel: '9:40 AM ET', title: 'Creditor letter', detail: 'Attached the letter.', who: 'Dana' },
    { key: '069000000000001AAA', kind: 'Note', dayLabel: 'Sunday', dateLabel: 'Oct 19', timeLabel: '4:02 PM ET', title: 'Spoke to client', detail: 'Wants to pause one payment.' },
    { key: '00a000000000001AAA', kind: 'Case comment', dayLabel: 'Saturday', dateLabel: 'Oct 18', timeLabel: '1:00 PM ET', title: 'Comment', detail: 'Checked plan.' }
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

function mount() {
  const el = createElement('c-previous-conversations-ai', { is: PreviousConversationsAI });
  el.recordId = '006000000000001AAA';
  document.body.appendChild(el);
  getHistory.emit(HISTORY);
  return el;
}

const text = (el) => el.shadowRoot.textContent;
const buttonByText = (el, label) =>
  Array.from(el.shadowRoot.querySelectorAll('button')).find((b) => b.textContent.trim().startsWith(label));

describe('c-previous-conversations-ai', () => {
  afterEach(() => {
    while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
    jest.clearAllMocks();
  });

  it('shows the client name, counts and every communication without calling the AI', async () => {
    const el = mount();
    await flush();
    expect(el.shadowRoot.querySelector('.pc-name').textContent).toBe('Blue Ridge Freight');
    expect(el.shadowRoot.querySelector('.pc-avatar').textContent).toBe('BR');
    const nums = Array.from(el.shadowRoot.querySelectorAll('.pc-stat-num')).map((n) => n.textContent);
    expect(nums).toEqual(['1', '1', '1']);
    expect(el.shadowRoot.querySelectorAll('.pc-comm')).toHaveLength(4);
    expect(text(el)).toContain('Generate AI Summary');
    expect(askAgent).not.toHaveBeenCalled();
  });

  it('gives a call its recording link, records a View source button, and a case comment no link', async () => {
    const el = mount();
    await flush();
    const rows = el.shadowRoot.querySelectorAll('.pc-comm');
    expect(rows[0].querySelector('a.pc-link').href).toBe('https://rec.example.com/1');
    expect(rows[1].querySelector('.pc-link-btn').dataset.key).toBe('02s000000000001AAA');
    expect(rows[3].querySelector('.pc-link-btn')).toBeNull();
    expect(rows[3].querySelector('a.pc-link')).toBeNull();
  });

  it('opens the email record from View source', async () => {
    const el = mount();
    await flush();
    el.shadowRoot.querySelectorAll('.pc-comm')[1].querySelector('.pc-link-btn').click();
    const pageReference = mockNavigate.mock.calls[0][0];
    expect(pageReference.type).toBe('standard__recordPage');
    expect(pageReference.attributes.recordId).toBe('02s000000000001AAA');
  });

  it('filters by type and by search text', async () => {
    const el = mount();
    await flush();
    const combo = el.shadowRoot.querySelector('lightning-combobox');
    combo.dispatchEvent(new CustomEvent('change', { detail: { value: 'email' } }));
    await flush();
    expect(el.shadowRoot.querySelectorAll('.pc-comm')).toHaveLength(1);

    combo.dispatchEvent(new CustomEvent('change', { detail: { value: 'all' } }));
    const search = el.shadowRoot.querySelector('lightning-input.pc-search');
    search.value = 'pause';
    search.dispatchEvent(new CustomEvent('change'));
    await flush();
    const rows = el.shadowRoot.querySelectorAll('.pc-comm');
    expect(rows).toHaveLength(1);
    expect(rows[0].textContent).toContain('Spoke to client');
  });

  it('renders the AI Summary card after Generate', async () => {
    askAgent.mockResolvedValue({ summary: CARD, configured: true });
    const el = mount();
    await flush();
    buttonByText(el, 'Generate AI Summary').click();
    await flush();
    await flush();
    expect(askAgent).toHaveBeenCalledWith({ recordId: '006000000000001AAA', agentId: 'xxxxxx', question: '' });
    expect(el.shadowRoot.querySelector('.pc-overall-text').textContent).toBe(CARD.overallSummary);
    expect(el.shadowRoot.querySelector('.pc-sentiment-label').textContent).toBe('Negative');
    expect(el.shadowRoot.querySelector('.pc-sentiment-label').className).toContain('pc-text-red');
    expect(text(el)).toContain('Client called twice this week');
    expect(text(el)).toContain('Can they skip October?');
    expect(text(el)).toContain('High priority');
    expect(el.shadowRoot.querySelector('.pc-due').textContent).toBe('Nov 3');
    expect(el.shadowRoot.querySelector('.pc-meeting-title').textContent).toBe('Review call');
    expect(text(el)).toContain('Last updated:');
    expect(text(el)).toContain('Regenerate');
  });

  it('shows the raw reply as the overall summary when the card could not be parsed', async () => {
    askAgent.mockResolvedValue({ text: 'The client is waiting on a date.' });
    const el = mount();
    await flush();
    buttonByText(el, 'Generate AI Summary').click();
    await flush();
    await flush();
    expect(el.shadowRoot.querySelector('.pc-overall-text').textContent).toBe('The client is waiting on a date.');
  });

  it('answers a typed question under the ask box', async () => {
    askAgent.mockResolvedValue({ text: 'The last call was on Oct 21.' });
    const el = mount();
    await flush();
    const input = el.shadowRoot.querySelector('lightning-input.pc-ask-input');
    input.value = 'When was the last call?';
    input.dispatchEvent(new CustomEvent('change'));
    await flush();
    buttonByText(el, 'Ask').click();
    await flush();
    await flush();
    expect(askAgent).toHaveBeenCalledWith(expect.objectContaining({ question: 'When was the last call?' }));
    expect(el.shadowRoot.querySelector('.pc-answer').textContent).toContain('The last call was on Oct 21.');
    expect(el.shadowRoot.querySelector('.pc-overall-text')).toBeNull();
  });

  it('drops a reply that arrives after the case changed', async () => {
    let resolve;
    askAgent.mockImplementation(() => new Promise((r) => { resolve = r; }));
    const el = mount();
    await flush();
    buttonByText(el, 'Generate AI Summary').click();
    el.recordId = '006000000000002AAA';
    getHistory.emit({ ...HISTORY, caseName: 'Other Client' });
    resolve({ summary: CARD });
    await flush();
    await flush();
    expect(el.shadowRoot.querySelector('.pc-overall-text')).toBeNull();
    expect(el.shadowRoot.querySelector('.pc-name').textContent).toBe('Other Client');
  });

  it('shows the notice when the AI is unavailable', async () => {
    askAgent.mockResolvedValue({ notice: 'The AI is unavailable right now.' });
    const el = mount();
    await flush();
    buttonByText(el, 'Generate AI Summary').click();
    await flush();
    await flush();
    expect(el.shadowRoot.querySelector('.pc-notice').textContent).toContain('unavailable');
  });
});
