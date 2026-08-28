# Intentional Marriage Assessment — standalone app

This is the standalone version, built to run on your own domain using
accounts you already have: GitHub, Vercel, and Supabase.

## What each piece does

- Supabase holds the data: everyone's category scores, plus a private
  code for each person to retrieve their own results later.
- Vercel serves the page itself (`index.html`) and gives it a real web
  address.
- GitHub holds the code and connects the two together, so pushing a
  change to GitHub automatically updates the live site.

## One-time setup

### 1. Set up the database

1. In your Supabase project, open **SQL Editor** → **New query**.
2. Paste in the contents of `schema.sql` from this folder and run it.
3. That's it. This creates one table and two narrow functions — no
   dashboard configuration needed beyond that.

### 2. Connect the app to your Supabase project

1. In Supabase, go to **Project Settings → API**.
2. Copy your **Project URL** and your **anon / public key** (not the
   service role key — that one should never appear in this file).
3. Open `index.html` and near the top, replace:
   ```js
   const SUPABASE_URL = "YOUR_SUPABASE_PROJECT_URL";
   const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
   ```
   with your real values. The anon key is safe to put directly in this
   file — it's meant to be public, and the database rules in
   `schema.sql` are what actually keep the data private, not secrecy of
   this key.

### 3. Push to GitHub

Create a new repository and push this folder to it (Claude Code can do
this for you if you'd rather not use the command line).

### 4. Deploy on Vercel

1. In Vercel, choose **Add New → Project** and import the GitHub repo.
2. No build settings are needed — this is a plain static file, so leave
   the framework preset as "Other" and deploy.
3. Once it's live, go to **Settings → Domains** and add
   `assessment.intentionalministries.com` (or whatever subdomain you'd
   like). Vercel will show you a DNS record to add wherever
   intentionalministries.com's domain is managed. It usually takes
   effect within a few minutes to a few hours.

### 5. Keep the free Supabase project from pausing

Supabase pauses free projects after 7 days with no activity. The
included `.github/workflows/keep-alive.yml` file pings your project
once a week automatically so this never becomes a problem.

To turn it on:
1. In your GitHub repo, go to **Settings → Secrets and variables →
   Actions**.
2. Add two repository secrets: `SUPABASE_URL` and `SUPABASE_ANON_KEY`,
   using the same values from step 2 above.
3. That's it — GitHub will run the ping automatically every Monday. You
   can also trigger it manually any time from the **Actions** tab.

## How the privacy model works, in plain terms

- Anyone can submit an assessment. That's the only thing the public key
  is allowed to do directly against the table.
- Looking up your own results requires the exact private code you were
  given after finishing. There is no way to browse or list everyone's
  results this way — only ever one exact match.
- A class leader's aggregate view only ever pulls category scores for a
  class code, never names, emails, private codes, or individual
  question answers. This is enforced in the database itself
  (`schema.sql`), not just hidden in the app's design, so it holds even
  if someone inspects the website's code.

## What's intentionally left out of this first version

- **Automatic emailing.** Right now, "email this to myself" opens the
  person's own email app with the code pre-filled — nothing is sent
  from a server. Real automated email (say, a class reminder a week
  later) would need an email-sending service like Resend plus a small
  Supabase Edge Function. Worth adding later if you want it, not
  necessary to get started.
- **Facilitator accounts or passwords.** Right now, anyone who knows a
  class code can view that class's aggregate results. That matches
  what you described wanting, but if you ever run multiple classes at
  once and want the aggregate view itself gated, that's a reasonable
  future addition.
