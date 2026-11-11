---
name: setup
description: Connect the msgblast app on this Mac. Use when the person wants agents to read comparisons, or when msgblast tools are missing. Never ask for keys or passwords.
---

# Set up msgblast

msgblast is a Mac app. Connect to the copy on this Mac. Never ask for keys or passwords.

## Check the app

Check that `/Applications/msgblast.app` exists. If it does not, tell the person to install msgblast from the msgblast site or the project README. The download is https://updates.msgblast.app/latest.zip; they drag msgblast.app into Applications. Stop until that app is installed.

## Turn on Outside agents

Ask them to open msgblast → Settings → Outside agents and turn on "Let agents on this Mac use msgblast".

## Call msgblast

Call `msgblast_status`. msgblast shows an approval prompt. They choose one level:

Read only: see agents, comparisons and replies; can't send anything.

Full access: everything, including sends to your AI agents and Messages contacts.

If the call fails with "msgblast is not running, or Settings → Outside agents is off", msgblast is quit or that switch is off. Ask them to open msgblast, turn the switch on, and then call `msgblast_status` again.
