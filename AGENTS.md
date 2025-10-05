# FleetLM Agents Guide

FleetLM is a clustered Phoenix application that delivers real-time conversations between a human and an assigned agent. Each session has a single human participant, a single agent participant, and all runtime logic preserves that pairing.

## Ground Rules

- Run `mix precommit` before you hand work back. It compiles with warnings-as-errors, formats, and runs tests.
- Use the built-in [`Req`](https://hexdocs.pm/req/Req.html) client for HTTP. Do not add `:httpoison`, `:tesla`, or `:httpc`.
- Never introduce new dependencies or services without explicit approval.
- Keep the default Tailwind v4 imports in `assets/css/app.css`; extend styling with Tailwind utility classes, not `@apply`.

## Golden Patterns

- Fail loudly on bad input. Prefer function-head pattern matching or `with` pipelines that enforce required keys. Only provide defaults when the product intentionally supports omissions.
- Validate telemetry metadata in explicit clauses. Treat unexpected or missing labels as an error path so instrumentation stays trustworthy.
- Destructure known structs/maps and coerce once. Avoid chaining `Map.get/3` with defaults—trust shape where it’s guaranteed, and guard upstream.
- Honour immutability: produce new assigns/state rather than mutating in place, and prefer small pure helpers for transformations.
- Design for back-pressure. The runtime assumes at-least-once delivery and sequence numbers; handle drains and retries with clear status signaling.

## Domain Assumptions

- Human → agent conversations only; there is no agent → agent or group routing.
- Every participant owns a single inbox process; sessions stream independently and are joined on demand with a `last_seq`.
- Messages are ULID-indexed, append-only, and replayable. Runtime caches (Session tail, Inbox snapshot) are transient and rebuildable.
- Agents integrate through debounced webhooks; rapid messages are batched using timers (default 500ms). We track webhook latency, batch efficiency, and end-to-end message timing via telemetry.

## Phoenix & LiveView Summary

- LiveView templates must start with `<Layouts.app flash={@flash} current_scope={@current_scope}>`.
- Use `<.form>` with `assigns.form = to_form(...)` and drive fields via `<.input field={@form[:field]}>`.
- Stick to `<.icon>` from `core_components` for hero icons; do not import other icon packs.
- Keep the UI polished: balanced spacing, subtle hover/transition states, and consistent typography.

## Frontend Notes

- Tailwind v4 import block must stay:
  ```
  @import "tailwindcss" source(none);
  @source "../css";
  @source "../js";
  @source "../../lib/fleetlm_web";
  ```
- No inline `<script>` tags. Extend behaviour via `assets/js/app.js` and Phoenix hooks with `phx-update="ignore"` when hooks own the DOM.
- Build micro-interactions via Tailwind utility classes and CSS transitions; avoid component libraries like daisyUI.

## Observability & Testing

- Emit telemetry via helpers in `Fleetlm.Observability.Telemetry`; add new events there so tags stay normalised.
- When you touch collections rendered in LiveView, prefer streams (`stream/3`) and track counts/empty states separately.
- Use `mix test`, `mix test --failed`, or file-scoped runs to iterate quickly. End every work session with `mix precommit`.

## Delivery Checklist

- Pattern-match inputs, return errors for invalid shapes.
- Update/invalidate caches when side effects change underlying data.
- Document new runtime behaviours in `docs/` if you alter process lifecycles or message flow.
