---
name: gradevault-credit-money-safety
description: Use this skill whenever discussing or changing GradeVault's credit/currency system — balance, top-ups, bonus credits, spend_credits, refunds, payment provider integration, reconciliation, or any notification tied to a credit event. Trigger even on casual mentions ("credits," "balance," "top-up," "bonus," "a user says their credits are missing"), since these are money-adjacent paths where a subtle bug becomes a trust incident or support ticket, not just a UI glitch.
---

# GradeVault Credit & Money Safety

## Core principle

Treat every credit-affecting code path as if real value is moving through it, even before a payment provider is fully wired in. A UI that shows "success" without backend confirmation is not success — it's a lie the user will find out about later, usually as a support ticket.

## Non-negotiable rules

- No silent balance changes. Every change to a user's balance must be traceable to a specific event with a timestamp and a cause.
- Purchase, top-up, bonus, reversal, and adjustment paths must stay distinguishable from each other — in the database, in the notification copy, and in any admin-facing view. Collapsing them into a generic "credit added" loses the information a support agent will need later.
- UI success must never be assumed from an optimistic update alone on a money path. Confirm the backend accepted the write before showing success state.
- Failed payments and failed top-ups need an explicit failure state, not a spinner that silently times out.
- Log every credit event with enough detail to answer "why does this user have this balance" without guessing.

## Checklist for any change touching credits

1. Does this path require backend confirmation before showing UI success, or does it currently assume success?
2. Is the event logged with type (top-up / bonus / spend / reversal / adjustment), amount, timestamp, and actor?
3. Is the grant type distinguishable at the data layer, not just reconstructed for display?
4. Can this RPC be called twice for one logical event (double-tap, retry, webhook redelivery)? If yes, is a duplicate call provably safe?
5. Is there a race condition if two credit-affecting actions hit the same user concurrently (spend during top-up, two admin grants at once)?
6. If this integrates a payment provider: what happens on partial failure (charged but DB write fails, or DB write succeeds but charge fails)? Both directions need a defined resolution, not "shouldn't happen."

## Failure modes to check for explicitly

- Notification fires but the balance write didn't actually commit.
- Balance write commits but the notification never fires — user has credits and doesn't know it, or worse, thinks they don't.
- Retry logic double-grants a top-up or double-charges a user.
- Admin CLI grant and a concurrent app-side spend interleave into a wrong final balance.
- Refund/chargeback path exists on paper but has no corresponding UI or notification — user is left confused with no explanation.

## What to verify after shipping any credit-path change

- A reconciliation query: sum of all logged credit events for a user equals their current balance. If it doesn't, something is writing balance without logging, or vice versa.
- Notification content matches the actual grant type that occurred (a Bonus grant should never read like a Top-up in the inbox).
- No orphaned credit rows — every balance-affecting row references a real, resolved event.
- Manually trigger the failure path (simulate a rejected write) and confirm the UI shows failure, not a false success.

## Escalation framing

If a change here is ambiguous or the tradeoffs aren't obvious, that ambiguity is itself the finding — surface it rather than picking a default silently. Money-path decisions are exactly the kind of thing that should become an ADR if this project starts using the ADR skill, since a wrong guess here is expensive to reverse after users have real balances riding on it.
