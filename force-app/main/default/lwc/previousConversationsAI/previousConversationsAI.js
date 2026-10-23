import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getHistory from '@salesforce/apex/PreviousConversationsController.getHistory';
import askAgent from '@salesforce/apex/PreviousConversationsController.askAgent';
import isAgentConfigured from '@salesforce/apex/PreviousConversationsController.isAgentConfigured';

/**
 * Business hours, in the ORG's zone rather than the viewer's.
 *
 * 15 of 133 active production users sit outside Eastern (8 GMT, 5 Los Angeles,
 * 2 Jamaica). Reading the local clock would start a London user's refreshes at
 * 4am Eastern and stop them at noon, so the window is evaluated in
 * America/New_York for everyone — the same zone the timeline renders its
 * timestamps in.
 */
const ZONE = 'America/New_York';
const WORKING_DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'];
const WEEK = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

/** Refresh slots, minutes past midnight Eastern: 9:00, 9:45 ... 16:30. */
const FIRST_SLOT = 9 * 60;
const LAST_SLOT_BEFORE = 17 * 60;
const SLOT_STEP = 45;
const MINUTE_MS = 60 * 1000;

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function kindGroup(kind) {
  const k = (kind || '').toLowerCase();
  if (k === 'call') return 'call';
  if (k.startsWith('email')) return 'email';
  if (k === 'note') return 'note';
  return 'other';
}

function easternNow(now) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: ZONE,
    weekday: 'short',
    hour: 'numeric',
    minute: 'numeric',
    second: 'numeric',
    hour12: false
  }).formatToParts(now);
  const read = (type) => {
    const part = parts.find((p) => p.type === type);
    return part ? Number(part.value) : 0;
  };
  const weekday = parts.find((p) => p.type === 'weekday');
  return {
    minutes: (read('hour') % 24) * 60 + read('minute'),
    seconds: read('second'),
    weekday: weekday ? weekday.value : null
  };
}

/** Cases this page has already fetched; see refreshOnceOnLoad. */
const SEEN_CASES = new Set();
const SEEN_LIMIT = 200;

function rememberCase(caseId) {
  if (SEEN_CASES.size >= SEEN_LIMIT) {
    SEEN_CASES.clear();
  }
  SEEN_CASES.add(caseId);
}

function daysToNextWorkday(weekday) {
  const start = WEEK.indexOf(weekday);
  for (let ahead = 1; ahead <= 7; ahead++) {
    if (WORKING_DAYS.includes(WEEK[(start + ahead) % 7])) {
      return ahead;
    }
  }
  return 1;
}

/** Milliseconds until the next refresh slot. */
function msUntilNextSlot(now) {
  const { minutes, seconds, weekday } = easternNow(now);
  if (weekday === null) {
    return null;
  }
  if (WORKING_DAYS.includes(weekday)) {
    for (let slot = FIRST_SLOT; slot < LAST_SLOT_BEFORE; slot += SLOT_STEP) {
      if (slot > minutes) {
        return (slot - minutes) * MINUTE_MS - seconds * 1000;
      }
    }
  }
  const days = daysToNextWorkday(weekday);
  const toMidnight = 24 * 60 - minutes;
  const total = toMidnight + (days - 1) * 24 * 60 + FIRST_SLOT;
  return total * MINUTE_MS - seconds * 1000;
}

/** 'YYYY-MM-DD' from the model as 'Nov 3'; anything else is shown as given. */
function shortDate(value) {
  if (!value) return '';
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!m) return value;
  const month = MONTHS[Number(m[2]) - 1];
  return month ? `${month} ${Number(m[3])}` : value;
}

/**
 * Previous conversations for one case, newest first, with an AI Summary on
 * request.
 *
 * Layout follows the AIsummarycon template (static resource on SIT): the AI
 * Summary hero, Overall Summary + Customer Sentiment, call / email / note
 * counts with the next key meeting, Key Insights, Customer Concerns,
 * Recommended Next Actions, and the history counts.
 *
 * Nothing calls the model on load. The summary is generated only when the case
 * manager presses Generate AI Summary (each press is one billed model call);
 * the timeline itself is SOQL plus one Data 360 query.
 */
export default class PreviousConversationsAI extends LightningElement {
  _recordId;

  @api
  get recordId() {
    return this._recordId;
  }

  set recordId(value) {
    if (value !== this._recordId) {
      this._recordId = value;
      this.handleCaseSwitch();
    }
  }

  @api cardTitle = 'Previous Conversations';

  /** Kept so existing page placements keep their property; the Models API ignores it. */
  @api agentId = 'xxxxxx';

  agentConfigured = true;

  @wire(isAgentConfigured, { agentId: '$agentId' })
  wiredAgentConfigured({ data }) {
    if (data === false) {
      this.agentConfigured = false;
    } else if (data === true) {
      this.agentConfigured = true;
    }
  }

  pickedId;
  history;
  error;
  loading = true;

  summary;
  summaryText;
  summaryAt;
  agentNotice;
  agentError;
  asking = false;
  askingSummary = false;

  refreshedOnLoad = false;
  timer;
  askToken = 0;

  connectedCallback() {
    this.scheduleNextSlot();
  }

  disconnectedCallback() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
  }

  scheduleNextSlot() {
    const delay = msUntilNextSlot(new Date());
    if (delay === null) {
      return;
    }
    // Held in a field and cleared in disconnectedCallback.
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.timer = setTimeout(() => {
      this.refreshOnSlot();
      this.scheduleNextSlot();
    }, Math.max(delay, MINUTE_MS));
  }

  /** Timeline only. The AI Summary stays on the button: a timer would bill with nobody reading. */
  refreshOnSlot() {
    if (!this.caseId || !this.wiredResult) {
      return;
    }
    refreshApex(this.wiredResult);
  }

  get caseId() {
    return this.recordId || this.pickedId;
  }

  get showPicker() {
    return !this.recordId;
  }

  wiredResult;

  @wire(getHistory, { recordId: '$caseId' })
  wiredHistory(result) {
    this.wiredResult = result;
    const { data, error } = result;
    this.loading = false;
    if (data) {
      this.history = data;
      this.error = undefined;
      this.refreshOnceOnLoad();
    } else if (error) {
      this.history = undefined;
      this.error = error?.body?.message || 'The conversation history could not be loaded.';
    }
  }

  refreshOnceOnLoad() {
    if (this.refreshedOnLoad) {
      return;
    }
    this.refreshedOnLoad = true;
    const key = this.caseId;
    if (!key) {
      return;
    }
    const seenBefore = SEEN_CASES.has(key);
    rememberCase(key);
    if (!seenBefore) {
      return;
    }
    refreshApex(this.wiredResult);
  }

  handlePick(event) {
    const next = event.detail.recordId;
    if (next !== this.pickedId) {
      this.pickedId = next;
      this.handleCaseSwitch();
    }
  }

  /** Everything tied to the old case goes the moment the case changes. */
  handleCaseSwitch() {
    this.loading = Boolean(this.caseId);
    this.history = undefined;
    this.error = undefined;
    this.refreshedOnLoad = false;
    this.resetAgent();
  }

  // ── Case ────────────────────────────────────────────────────────────────────

  get needsCase() {
    return !this.caseId;
  }

  get hasCase() {
    return Boolean(this.caseId);
  }

  // ── Timeline ────────────────────────────────────────────────────────────────

  get rawEntries() {
    return this.history?.entries || [];
  }

  get hasEntries() {
    return this.rawEntries.length > 0;
  }

  get isEmpty() {
    return Boolean(this.caseId) && !this.loading && !this.error && !this.hasEntries;
  }

  get notice() {
    return this.history?.notice;
  }

  /** Counts for the Calls / Emails / Notes tiles, straight from the timeline. */
  get stats() {
    let calls = 0;
    let emails = 0;
    let notes = 0;
    this.rawEntries.forEach((e) => {
      const g = kindGroup(e.kind);
      if (g === 'call') calls += 1;
      else if (g === 'email') emails += 1;
      else if (g === 'note') notes += 1;
    });
    return { calls, emails, notes };
  }

  // ── AI Summary ──────────────────────────────────────────────────────────────

  get hasSummary() {
    return Boolean(this.summary);
  }

  get hasSummaryText() {
    return !this.summary && Boolean(this.summaryText);
  }

  get showSummaryPrompt() {
    return this.hasCase && !this.summary && !this.summaryText && !this.askingSummary;
  }

  get overallSummary() {
    return this.summary?.overallSummary || 'No overall summary was returned.';
  }

  get sentimentLabel() {
    return this.summary?.sentimentLabel || 'Unknown';
  }

  get sentimentNote() {
    return this.summary?.sentimentNote;
  }

  /**
   * Good green, Neutral blue, Needs Attention amber, Unhappy red, Unknown gray.
   * Positive / Negative are older words for Good / Needs Attention.
   */
  get sentimentTone() {
    const label = this.sentimentLabel.toLowerCase();
    if (label === 'good' || label === 'positive') return 'green';
    if (label === 'neutral') return 'blue';
    if (label === 'needs attention' || label === 'negative') return 'amber';
    if (label === 'unhappy') return 'red';
    return 'gray';
  }

  get sentimentIcon() {
    const tone = this.sentimentTone;
    if (tone === 'green') return 'utility:like';
    if (tone === 'amber') return 'utility:warning';
    if (tone === 'red') return 'utility:dislike';
    return 'utility:info';
  }

  get sentimentIconClass() {
    return `pc-round-icon pc-tone-${this.sentimentTone}`;
  }

  get sentimentLabelClass() {
    return `pc-sentiment-label pc-text-${this.sentimentTone}`;
  }

  get keyInsights() {
    return (this.summary?.keyInsights || []).map((text, i) => ({ id: `ki-${i}`, text }));
  }

  get hasKeyInsights() {
    return this.keyInsights.length > 0;
  }

  get customerConcerns() {
    return (this.summary?.customerConcerns || []).map((text, i) => ({ id: `cc-${i}`, text }));
  }

  get hasCustomerConcerns() {
    return this.customerConcerns.length > 0;
  }

  get nextActions() {
    return (this.summary?.nextActions || []).map((a, i) => {
      const p = (a.priority || '').toLowerCase();
      const tone = p === 'high' ? 'red' : p === 'medium' ? 'amber' : p === 'low' ? 'green' : 'gray';
      return {
        id: `na-${i}`,
        action: a.action,
        priority: a.priority ? (p === 'high' ? 'High priority' : a.priority) : '',
        hasPriority: Boolean(a.priority),
        priorityClass: `pc-pill pc-tone-${tone}`,
        due: shortDate(a.dueDate),
        hasDue: Boolean(a.dueDate)
      };
    });
  }

  get hasNextActions() {
    return this.nextActions.length > 0;
  }

  get meeting() {
    const m = this.summary?.nextKeyMeeting;
    if (!m) return null;
    return {
      title: m.title || 'Next meeting',
      when: [shortDate(m.meetingDate), m.meetingTime].filter(Boolean).join(' · ')
    };
  }

  get hasMeeting() {
    return Boolean(this.meeting);
  }

  get lastUpdated() {
    return this.summaryAt ? `Last updated: ${this.summaryAt}` : '';
  }

  get generateLabel() {
    if (this.askingSummary) return 'Generating…';
    return this.summary || this.summaryText ? 'Regenerate' : 'Generate AI Summary';
  }

  /** Nothing to summarise, nothing configured, or a call already in flight. */
  get askDisabled() {
    return this.asking || !this.agentConfigured || !this.hasEntries;
  }

  get agentUnset() {
    return !this.agentConfigured;
  }

  resetAgent() {
    // Bumping the token orphans any request still in flight.
    this.askToken += 1;
    this.summary = undefined;
    this.summaryText = undefined;
    this.summaryAt = undefined;
    this.agentNotice = undefined;
    this.agentError = undefined;
    this.asking = false;
    this.askingSummary = false;
  }

  handleGenerate() {
    return this.send();
  }

  /**
   * One summary request about the CURRENT case. A reply that comes back after
   * the case changed is dropped (token check), so one client's summary never
   * lands under another client's case.
   */
  async send() {
    if (this.askDisabled) {
      return;
    }
    this.askToken += 1;
    const token = this.askToken;
    this.asking = true;
    this.askingSummary = true;
    this.agentNotice = undefined;
    this.agentError = undefined;
    try {
      const res = await askAgent({
        recordId: this.caseId,
        agentId: this.agentId,
        question: ''
      });
      if (token !== this.askToken) {
        return;
      }
      this.agentNotice = res?.notice;
      if (res?.summary || res?.text) {
        this.summary = res?.summary || undefined;
        this.summaryText = res?.summary ? undefined : res?.text;
        this.summaryAt =
          new Intl.DateTimeFormat('en-US', {
            timeZone: ZONE,
            month: 'short',
            day: 'numeric',
            hour: 'numeric',
            minute: '2-digit'
          }).format(new Date()) + ' ET';
      }
    } catch (e) {
      if (token !== this.askToken) {
        return;
      }
      this.agentError = e?.body?.message || 'The AI could not be reached.';
    } finally {
      if (token === this.askToken) {
        this.asking = false;
        this.askingSummary = false;
      }
    }
  }
}
