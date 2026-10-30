# Marketing drafts (English) — Draft · Unpublished

> **Status: draft · unpublished.** Nothing has been posted or sent. Before posting, replace `{SITE_URL}` with the real address and check that checkout links are live (if not, use "Pro is coming soon").
> No made-up numbers, reviews or ratings. Prices follow `windows/buni_pro.py` and `ProManager.swift`: $3/mo, $24/yr, $49 lifetime; 14-day trial for new users, 30 days for existing; 30% off individual packs for Pro.
> This draft only describes what Pro covers today: pro characters & color variants, cloud sync, pack discount. (Squad scheduling/parallel isn't wired to Pro yet, so it is not listed as a Pro perk. The older `intro.md` and `launch-posts.md` mention it — align them with this file before posting.)

## 1. Product copy

**One line**
A pixel-art rabbit in the corner of your screen that shows what Claude Code is doing.

**Short**
Buni is a macOS and Windows app that shows your Claude Code session state — thinking, using a tool, asking permission, done — as a pixel rabbit in the corner of your screen. No more staring at the terminal.

**Medium**
Ever started Claude Code on a task, gone off to do something else, then kept going back to the terminal to see if it finished? Buni puts a small rabbit panel on your screen for each session and shows whether it's thinking, waiting for permission, or done — with gestures and speech bubbles.

- Allow / Allow all / Deny right from the permission bubble
- Token usage gauge
- A different character per session, plus a coin shop for outfits (coins come from finished tasks)
- Keeps running with the laptop lid closed; chat rooms by code (up to 10 people)
- No analytics or remote collection in the app

Everything that exists today stays free. Pro ($3/mo, $24/yr, $49 lifetime) adds pro characters & color variants and cloud sync, and takes 30% off individual packs. New users get a 14-day Pro trial, existing users 30 days.

## 2. Launch post

**Title:** I made a pixel rabbit that tells you what Claude Code is doing 🐰

When I leave Claude Code working, I keep checking the terminal: still thinking? waiting for permission? done? So I built Buni, a small rabbit per session in the corner of your screen.

**How it works**
Claude Code hooks write events to a local file; the app reads it and updates the rabbit. There's no server.

**What it does**
- Distinct looks and speech bubbles for thinking / tool use / permission request / done
- Allow / Allow all / Deny from the bubble
- Token usage gauge
- A different character per session and a coin shop
- Keep-running with the lid closed; chat rooms by code (up to 10)
- macOS (Swift) and Windows (Python)

**Pricing**
Existing features stay free. Pro is optional: $3/month, $24/year or $49 lifetime, for pro characters & color variants, cloud sync and 30% off individual packs. License keys are signed and verified offline — no server check.

Honest feedback on what's missing or on the pricing would help a lot.
{SITE_URL} · https://github.com/EloyYang/buni

## 3. Community / social posts

**Reddit** (r/ClaudeAI, r/SideProject, r/macapps — check each sub's self-promo rules and flair first)
Title: I made a pixel-art rabbit that shows what Claude Code is doing (macOS + Windows)
Body: I kept alt-tabbing to the terminal to check whether Claude Code was still thinking, waiting for permission, or done. So I built Buni — a small rabbit panel per session. Allow/deny from the bubble, token gauge, a different character per session, hooks → local file, no server, no analytics in the app. Core is free; optional Pro is $3/mo, $24/yr or $49 lifetime. What would make it more useful for you? {SITE_URL}

**Hacker News (Show HN)**
Title: Show HN: Buni – a pixel rabbit that shows what Claude Code is doing
Body: Hooks write events to a JSONL file, the app polls it and animates one rabbit per session. macOS (Swift) and Windows (Python/Tkinter). Licenses are Ed25519-signed keys checked offline. Feedback welcome. https://github.com/EloyYang/buni

**X (≤280 chars)**
Got tired of alt-tabbing to see if Claude Code was done, so I made Buni 🐰 — a pixel rabbit in the corner of your screen showing thinking / permission request / done. macOS + Windows, core free.
{SITE_URL}

**Thread (3 posts)**
1) The post above + a short clip
2) Allowing a permission request right from the bubble — "no need to go back to the terminal"
3) "Pro is $3/mo, $24/yr or $49 lifetime. Everything that exists today stays free. No analytics in the app."

**Product Hunt**
- Tagline: A pixel rabbit that shows what Claude Code is doing
- Description: Buni sits in the corner of your screen and shows each Claude Code session's state — thinking, using a tool, asking permission, done. Allow/deny from the bubble, track token usage, customize with a coin shop. macOS & Windows. Core is free; Pro is optional.

## 4. Ad copy (not run)

| Use | Copy |
|---|---|
| Headline | Let the rabbit watch the terminal |
| Headline | Claude Code done? The rabbit tells you |
| Headline | Approve permissions right from the bubble |
| Description | Thinking, permission, done — shown by a pixel rabbit. macOS & Windows. |
| Description | Core features free. Pro from $3/mo, 14-day trial. |
| Button | Try it free / Learn more |

## 5. Fact check

| Claim | Source |
|---|---|
| $3 / $24 / $49 | `PLAN_PRICE_CENTS` in `windows/buni_pro.py`, CLAUDE.md |
| 14-day (new) / 30-day (existing) trial, 30% pack discount | `TRIAL_DAYS_NEW/EXISTING`, `PRO_PACK_DISCOUNT_PERCENT` |
| Pro = pro characters, color variants, cloud sync | CLAUDE.md "Pro / 라이선스" |
| Chat up to 10, no analytics, offline signed keys | CLAUDE.md, `docs/privacy.html`, `license-spec.md` |
| Not used | user counts, reviews, ratings, "best/only" claims, squad as a Pro perk |
