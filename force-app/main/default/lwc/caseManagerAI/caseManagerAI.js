import { LightningElement, api, track } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";

import canViewAllCases from "@salesforce/apex/CaseManagerAIController.canViewAllCases";
import getMorningDigest from "@salesforce/apex/CaseManagerAIController.getMorningDigest";
import getAccountOpportunities from "@salesforce/apex/CsCaseManagerDashboardController.getAccountOpportunities";
import CaseWorkModal from "c/caseWorkModal";

import USER_ID from "@salesforce/user/Id";

/**
 * Must match CaseManagerAIDigestService.SUB_MARKER. A finding line carries it;
 * a case header line does not.
 */
const SUB_MARKER = "\u21B3 ";

/**
 * Case Manager AI — the morning triage summary for a case manager's book.
 *
 * One mode, wherever the component is dropped: press Generate, Apex reads the
 * running user's whole book and returns a ranked triage, and the card narrates
 * it. Nothing is stored and nothing is scheduled, so every press reflects field
 * values at that moment rather than a 06:30 snapshot.
 *
 * The ranked, clickable case list and the single-case briefing panel it opened
 * were removed on 2026-08-20 at the team's direction — this component is the
 * summary card only. CaseManagerAIService and the Agentforce action are
 * untouched and still serve the agent.
 *
 * Everything is filtered server-side to cases where the running user is the
 * Case Manager; this component never sends a user id.
 */
export default class CaseManagerAI extends LightningElement {
  @api recordId;
  @api cardTitle = "Case Manager AI";
  /**
   * Retained only because Salesforce refuses to drop a design property that is
   * live on a Lightning page. None of these five is read: the single-case
   * briefing and its Ask Case Manager AI button were removed on 2026-08-20, so
   * agentId joined the other four.
   *
   * To actually remove them, first remove this component from
   * Opportunity_Record_Page_Three_Column, Creditor_Dashboard, Home_Page_V3
   * (nagadsb) and CS_Workspace (SIT), then delete the properties, then put the
   * component back.
   */
  @api agentId;
  @api maxCases;
  @api hideCaseList;
  @api autoRead;
  @api avatarModel;

  @track digest;

  /** True once the reader has asked to see the bands held back. */
  showLowerBand = false;

  isLoadingDigest = false;

  /** True once Generate has been pressed at least once this page view. */
  hasGenerated = false;

  /** Characters revealed so far by the typing effect. */
  typedText = "";
  typingDone = false;
  _typeTimer;
  _replayTimer;
  errorMessage;
  viewAll = false;

  userId = USER_ID;

  // ───────────────────────── lifecycle ─────────────────────────

  /** Characters per tick and tick length — ~40 chars a second. */
  TYPE_CHARS_PER_TICK = 2;
  TYPE_TICK_MS = 50;
  /** How often the brief re-types itself, per the 5-minute requirement. */
  REPLAY_MS = 300000;

  connectedCallback() {
    this.bootstrap();
  }

  /** Timers outlive the component unless cleared, so always clear them. */
  disconnectedCallback() {
    this.stopTimers();
  }

  async bootstrap() {
    try {
      this.viewAll = await canViewAllCases();
    } catch (e) {
      // Non-fatal: worst case the badge is missing.
      this.viewAll = false;
    }

    // The component reports on the WHOLE book on every page it is placed on,
    // including a record page. It deliberately does NOT resolve the host
    // record's own case and narrow to it — a case manager opening one
    // Opportunity still wants to see everything assigned to them, and the
    // single-case view is reached by picking a case from the list below.
    // `recordId` is still declared so the platform can pass it on a record
    // page; it is intentionally unused.
    // No else: in list mode the digest is NOT built on page load. It reads the
    // whole book - around ten queries - and most visits to a Home page are not
    // a request for a morning triage. The user asks for it with Generate.
  }

  // ───────────────────────── data loading ─────────────────────────

  /**
   * Non-fatal by design: a failed digest hides the banner but must never stop
   * a case manager reading their caseload.
   */
  /**
   * Builds the digest on demand.
   *
   * Deliberately not called from connectedCallback. Nothing about this is
   * scheduled or cached: every press reads the running user's whole book and
   * recomputes the triage from current field values, so what comes back is
   * true at the moment it is asked for rather than true at 06:30.
   */
  async handleGenerate() {
    this.hasGenerated = true;
    this.errorMessage = undefined;
    this.isLoadingDigest = true;
    try {
      this.digest = await getMorningDigest();
      this.startTyping();
    } catch (e) {
      this.digest = undefined;
      this.errorMessage = this.readError(e);
    } finally {
      this.isLoadingDigest = false;
    }
  }

  /**
   * Rebuilds the triage. This used to call this.loadDigest(), which does not
   * exist in this bundle and threw a TypeError on every press — fixed
   * 2026-08-20. handleGenerate is the method that actually reads the book.
   */
  /**
   * Reveals or hides the lower-severity cases.
   *
   * They are held back rather than dropped: a case manager reading four reds
   * should not have to assume the book is otherwise clean, but nor should the
   * ambers compete for attention while a red is open.
   */
  handleToggleLowerBand() {
    this.showLowerBand = !this.showLowerBand;
  }

  handleRefresh() {
    this.handleGenerate();
  }

  // ───────────────────────── AI writing effect ─────────────────────────

  /**
   * Types the brief out on arrival, then replays every five minutes.
   *
   * The plain text is typed rather than the stored markup: revealing
   * "<strong>Acme" one character at a time would print raw tags on screen.
   * Once the last character lands, typingDone swaps the rendering over to the
   * bolded rich-text version, so the finished state is correctly formatted.
   */
  startTyping() {
    this.stopTimers();
    const full = this.plainNarrative;
    this.typedText = "";
    this.typingDone = false;
    if (!full) {
      this.typingDone = true;
      return;
    }

    let cursor = 0;
    this._typeTimer = window.setInterval(() => {
      cursor += this.TYPE_CHARS_PER_TICK;
      this.typedText = full.slice(0, cursor);
      if (cursor >= full.length) {
        window.clearInterval(this._typeTimer);
        this._typeTimer = undefined;
        this.typingDone = true;
        this._replayTimer = window.setTimeout(
          () => this.startTyping(),
          this.REPLAY_MS
        );
      }
    }, this.TYPE_TICK_MS);
  }

  stopTimers() {
    if (this._typeTimer) {
      window.clearInterval(this._typeTimer);
      this._typeTimer = undefined;
    }
    if (this._replayTimer) {
      window.clearTimeout(this._replayTimer);
      this._replayTimer = undefined;
    }
  }

  /** Stored narrative with markup stripped, for the typing phase. */
  get plainNarrative() {
    const raw = this.digest?.narrative;
    return raw ? raw.replace(/<[^>]+>/g, "") : "";
  }

  /**
   * One entry per line. Apex decides the point boundaries — a header line per
   * case, then one line per finding prefixed with "\u21B3 ".
   *
   * The marker is stripped here and turned into an indent: a finding is not a
   * peer of the case it belongs to, and rendering both with the same bullet is
   * what made the card read as a wall of text.
   */
  get narrativePoints() {
    const source = this.typingDone
      ? this.digest?.narrative || ""
      : this.typedText;
    const lines = source.split("\n").filter((line) => line.trim().length);
    return lines.map((text, index) => {
      const isSub = text.startsWith(SUB_MARKER);
      return {
        key: index,
        text: isSub ? text.slice(SUB_MARKER.length) : text,
        isSub,
        itemClass: isSub
          ? "cm-brief__point cm-brief__point--sub"
          : "cm-brief__point",
        isLast: index === lines.length - 1
      };
    });
  }

  get isTyping() {
    return !this.typingDone;
  }

  get scopeLabel() {
    return this.viewAll ? "All case managers" : "My cases";
  }

  // ───────────────────────── morning digest ─────────────────────────

  /**
   * Shown only when something actually breached. A banner that renders on a
   * quiet book trains people to scroll past it, so it is gone rather than
   * reassuring.
   */
  get showDigest() {
    return !!this.digest && !this.isLoadingDigest && this.hasDigestAlerts;
  }

  get showGenerate() {
    return !this.isLoadingDigest;
  }

  get generateLabel() {
    return this.hasGenerated ? 'Regenerate' : 'Generate';
  }

  /**
   * The cases the card shows by default: the worst band present.
   *
   * Apex decides which band that is and stamps inTopBand, so this is a filter
   * rather than a second implementation of the same rule.
   */
  get topCases() {
    return this.decorate((this.digest?.alerts || []).filter((a) => a.inTopBand));
  }

  get lowerCases() {
    return this.decorate((this.digest?.alerts || []).filter((a) => !a.inTopBand));
  }

  get lowerCount() {
    return (this.digest?.alerts || []).filter((a) => !a.inTopBand).length;
  }

  get hasLowerBand() {
    return this.lowerCount > 0;
  }

  get lowerToggleLabel() {
    const n = this.lowerCount;
    const noun = `lower-priority case${n === 1 ? "" : "s"}`;
    return this.showLowerBand ? `Hide the ${n} ${noun}` : `Show ${n} ${noun}`;
  }

  get lowerToggleIcon() {
    return this.showLowerBand ? "utility:chevronup" : "utility:chevrondown";
  }

  /** Structured rendering replaces the narrative once typing has finished. */
  get showCaseCards() {
    return this.typingDone && (this.digest?.alerts || []).length > 0;
  }

  /**
   * Adds what the template needs and nothing the service should have known:
   * a record URL, a severity class, and findings keyed for iteration.
   *
   * The account link is built here rather than in Apex because it is
   * presentation. A relative URL keeps it correct in every org.
   */
  async handleAccountClick(event) {
    const accountId = event.currentTarget.dataset.accountId;
    if (!accountId) return;
    const opportunityIds = await this._buildOpportunityIds(accountId, null);
    CaseWorkModal.open({
      size:                  'full',
      accountId,
      opportunityIds,
      selectedOpportunityId: null,
      caseIds:               []
    });
  }

  async handleCaseClick(event) {
    const accountId     = event.currentTarget.dataset.accountId;
    const opportunityId = event.currentTarget.dataset.opportunityId;
    if (!accountId) return;
    const opportunityIds = await this._buildOpportunityIds(accountId, opportunityId);
    CaseWorkModal.open({
      size:                  'full',
      accountId,
      opportunityIds,
      selectedOpportunityId: opportunityId || null,
      caseIds:               []
    });
  }

  async _buildOpportunityIds(accountId, specificOppId) {
    try {
      const allIds = (await getAccountOpportunities({ accountId })) || [];
      if (!specificOppId) return allIds;
      const rest = allIds.filter(id => id !== specificOppId);
      return [specificOppId, ...rest];
    } catch (e) {
      return specificOppId ? [specificOppId] : [];
    }
  }

  decorate(alerts) {
    return alerts.map((a) => ({
      id: a.opportunityId,
      name: a.opportunityName,
      accountName: a.accountName,
      accountId: a.accountId,
      isLinked: !!a.accountId,
      notLinked: !a.accountId,
      // Only worth printing separately when it actually says something new.
      showAccountName:
        !!a.accountName && a.accountName !== a.opportunityName,
      severity: a.severity,
      pillClass: `cm-pill cm-pill--${(a.severity || "info").toLowerCase()}`,
      findings: (a.triggers || []).map((t, i) => ({ key: `${a.opportunityId}-${i}`, text: t }))
    }));
  }

  /** Before the first press there is nothing to report, and that is not a fault. */
  get showPrompt() {
    return !this.hasGenerated && !this.isLoadingDigest;
  }

  /**
   * Nothing flagged means there is nothing left to render, so say so. An empty
   * panel reads as a broken component.
   */
  get showQuietState() {
    return this.hasGenerated && !this.isLoadingDigest && !this.hasDigestAlerts;
  }

  get quietStateLabel() {
    const n = this.digest?.caseCount;
    return n
      ? `All clear — nothing needs your attention across ${n} case${
          n === 1 ? "" : "s"
        }.`
      : "All clear — nothing needs your attention.";
  }

  get digestSeverity() {
    return (this.digest?.severity || "Clear").toLowerCase();
  }

  get digestLabel() {
    switch (this.digestSeverity) {
      case "red":
        return "RED ALERT";
      case "amber":
        return "NEEDS ATTENTION";
      case "info":
        return "FOR AWARENESS";
      default:
        return "ALL CLEAR";
    }
  }

  /**
   * "generated 3:03 PM from 214 activities across your book"
   *
   * The activity clause is dropped entirely at zero rather than printing
   * "from 0" — a brief that admits it read nothing invites being ignored.
   */
  get digestProvenance() {
    const time = new Intl.DateTimeFormat("en-US", {
      hour: "numeric",
      minute: "2-digit"
    }).format(new Date(this.digest.generatedOn));
    const n = this.digest.activityCount;
    return n
      ? `generated ${time} from ${n} activities across your book`
      : `generated ${time}`;
  }

  get hasDoFirst() {
    return this.doFirstItems.length > 0;
  }

  /** Stored newline-separated by the generator; order is priority order. */
  get doFirstItems() {
    // The live digest returns doFirst as a List<String>; the old stored record
    // held it as one newline-joined field. Handle both so the getter does not
    // depend on which shape the Apex side happens to send.
    const raw = this.digest?.doFirst;
    if (!raw) {
      return [];
    }
    const lines = Array.isArray(raw) ? raw : String(raw).split("\n");
    return lines.filter((line) => line && line.trim().length);
  }

  /** Red and amber counts are what make a brief worth showing. */
  get hasDigestAlerts() {
    const d = this.digest;
    return !!d && ((d.redCount || 0) > 0 || (d.amberCount || 0) > 0);
  }

  readError(error) {
    return (
      error?.body?.message ||
      error?.message ||
      "Something went wrong loading this case."
    );
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }
}