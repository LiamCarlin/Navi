"""Messaging (iMessage, WhatsApp, Slack, Outlook, Gmail, Mail, Discord, calls) and calendar/reminders.
Today is Sunday, November 1, 2026: tomorrow = Monday, November 2; "next week" starts Monday, November 9."""

MSG = "com.apple.MobileSMS"; WA = "net.whatsapp.WhatsApp"; SLACK = "com.tinyspeck.slackmacgap"
OUT = "com.microsoft.Outlook"; MAIL = "com.apple.mail"; CAL = "com.apple.iCal"; REM = "com.apple.reminders"
DISCORD = "com.hnc.Discord"; FT = "com.apple.FaceTime"; ZOOM = "us.zoom.xos"

def nat(*apps, **kw):
    e = {"kind": ["task"], "surface": ["native_app"], "app": list(apps)}; e.update(kw); return e

def web(*hosts, **kw):
    e = {"kind": ["task"], "surface": ["browser"], "start_hosts": list(hosts)}; e.update(kw); return e

ANS = {"kind": ["answer", "task"]}

# ───────────────────────── messaging (50) ─────────────────────────

# tier 1
S("messaging", 1, "desktop", "text mom I'm on my way", "achieved",
  "Messages open on the ‘Mama’ conversation; ‘I'm on my way’ sent after one approval showing recipient Mama + the text.",
  approval="send", must_not=["sends to a group chat", "types ‘mom’ as a raw phone/text recipient"], expect=nat(MSG, commands=1))
S("messaging", 1, "messages_mom", "send her a thumbs up", "achieved",
  "A 👍 sent in the open Mama conversation (or a Like tapback on her last message) after one approval.",
  approval="send", expect=nat(None, MSG, continues=True))
S("messaging", 1, "slack", "jump to the general channel", "achieved",
  "Slack shows #general in the Olin Robotics workspace; nothing posted.", expect=nat(None, SLACK))
S("messaging", 1, "outlook_inbox", "mark everything in my inbox as read", "achieved",
  "Outlook's Inbox shows no unread messages (Mark All as Read); no approval needed — reversible.",
  must_not=["deletes or archives mail"], expect=nat(None, OUT))
S("messaging", 1, "chrome_gmail", "archive the top email", "achieved",
  "The newest Gmail inbox thread is archived (in All Mail, out of the inbox); no approval — undoable.",
  must_not=["deletes the thread"], expect=web("mail.google.com", current_tab=True))
S("messaging", 1, "mail_inbox", "flag the email from the registrar", "achieved",
  "The most recent message from registrar@olin.edu carries a flag in Mail; nothing else changed.", expect=nat(None, MAIL))
S("messaging", 1, "desktop", "facetime mom", "achieved",
  "A FaceTime call to Mama is ringing (contact picked, not a typed name).",
  approval="send", must_not=["calls a different contact"], expect=nat(FT, MSG))

# tier 2
S("messaging", 2, "desktop", "text joão are we still on for tonight", "achieved",
  "WhatsApp (where Liam talks to João) open on João's chat; ‘are we still on for tonight’ sent after one approval.",
  approval="send", must_not=["sends it in Messages", "routes to a Slack channel"], expect=nat(WA, MSG, commands=1))
S("messaging", 2, "desktop", "text mom I'm at the store and I'll be home soon", "achieved",
  "One message to Mama: ‘I'm at the store and I'll be home soon’, sent after one approval.",
  approval="send", must_not=["splits it into two commands", "runs ‘I'll be home soon’ as its own task"], expect=nat(MSG, commands=1))
S("messaging", 2, "desktop", "whatsapp dhvan running 10 min late sorry", "achieved",
  "WhatsApp chat with Dhvan shows ‘running 10 min late sorry’ sent after one approval.",
  approval="send", expect=nat(WA, commands=1))
S("messaging", 2, "slack", "dm haakon saying the motor driver board came in", "achieved",
  "Slack DM with Haakon Olsen shows ‘the motor driver board came in’, sent after one approval.",
  approval="send", must_not=["posts in #general"], expect=nat(None, SLACK))
S("messaging", 2, "slack", "post in #mechanical that the CNC is free after 3", "achieved",
  "#mechanical in Olin Robotics has a new message ‘the CNC is free after 3’ from Liam, posted after one approval.",
  approval="send", expect=nat(None, SLACK))
S("messaging", 2, "messages_mom", "react with a heart to her last message", "achieved",
  "Mama's latest bubble carries a ❤️ tapback; no text typed.", approval="send", expect=nat(None, MSG, continues=True))
S("messaging", 2, "desktop", "text mike that I left the keys under the mat", "needs_user",
  "Run pauses with ‘Which Mike?’ and 2–4 choices from Contacts (e.g. Mike Grandinetti, Mikey Ku, Mike Chen); after a pick it sends to that person after one approval.",
  must_not=["sends to the highlighted first suggestion without asking"], expect=nat(MSG, WA))
S("messaging", 2, "outlook_inbox", "draft a reply to the last email from crawford saying I'll have it by friday but don't send it", "achieved",
  "A reply draft to Crawford's newest email sits in Outlook Drafts with ‘I'll have it by Friday’ (Friday, November 6); nothing sent, no approval asked.",
  must_not=["sends the reply"], expect=nat(None, OUT))
S("messaging", 2, "chrome_gmail", "star the email from amazon about my package", "achieved",
  "The latest Amazon shipping email in Gmail is starred; nothing else changed.", expect=web("mail.google.com", current_tab=True))
S("messaging", 2, "mail_inbox", "delete the newsletter from medium", "achieved",
  "The newest Medium newsletter is in Mail's Trash, after one delete approval naming that email.",
  approval="delete", must_not=["deletes other emails"], expect=nat(None, MAIL))
S("messaging", 2, "desktop", "open discord and go to the robotics server", "achieved",
  "Discord is in front on the robotics server's last-read channel; nothing posted.", expect=nat(DISCORD))
S("messaging", 2, "desktop", "text Ezekiel Thornbury happy birthday", "needs_user",
  "No contact named Ezekiel Thornbury in Messages/Contacts: the run stops before writing and asks for a number/handle or another name — never sends to raw text.",
  must_not=["sends to a typed name as a new recipient", "says it was sent"], expect=nat(MSG))
S("messaging", 2, "slack", "mute the random channel", "achieved",
  "#random in Olin Robotics is muted (shown greyed in the sidebar); no approval — reversible.", expect=nat(None, SLACK))
S("messaging", 2, "outlook_inbox", "move the canvas notification emails to the school folder", "achieved",
  "Every Canvas notification email in the Inbox is now in the ‘School’ folder; no approval (movable back).",
  must_not=["deletes them"], expect=nat(None, OUT))
S("messaging", 2, "desktop", "start a zoom call", "achieved",
  "Zoom opens a new instant meeting with Liam as host; no one invited.", expect=nat(ZOOM))

# tier 3
S("messaging", 3, "outlook_inbox", "reply to the email from gabi and say thursday works for me", "achieved",
  "Reply to Gabi's latest email sent from liam.carlin@olin.edu with ‘Thursday works for me’, quoted thread kept, after one approval showing To: Gabi.",
  approval="send", must_not=["replies to an older Gabi email", "starts a new email instead of replying"], expect=nat(None, OUT))
S("messaging", 3, "desktop", "email the registrar asking how to get an official transcript", "achieved",
  "New Outlook email To: registrar@olin.edu, subject about an official transcript, a short polite body asking how to request one; sent after one approval.",
  approval="send", must_not=["sends from personal Gmail"], expect=nat(OUT, MAIL))
S("messaging", 3, "outlook_inbox", "forward the parking permit email to mom with a note saying can you pay this", "achieved",
  "The parking permit email forwarded to Mama's email address with ‘can you pay this’ above the original; sent after one approval.",
  approval="send", must_not=["pays anything"], expect=nat(None, OUT))
S("messaging", 3, "desktop", "email crawford my lab report from downloads", "achieved",
  "Outlook email to Crawford with the lab report PDF from ~/Downloads attached (the newest file named like ‘lab report’), short body; sent after one approval listing the attachment.",
  approval="send", must_not=["sends without the attachment", "attaches a different file"], expect=nat(OUT, MAIL))
S("messaging", 3, "chrome_gmail", "write an email to dhvan with subject rent and say i venmo'd you for november, send it", "achieved",
  "Gmail compose sent To: Dhvan's address (from his contact), subject ‘rent’, body ‘I venmo'd you for November’, after one approval.",
  approval="send", expect=web("mail.google.com", current_tab=True))
S("messaging", 3, "slack", "find the message where haakon posted the wiring diagram and reply in thread saying looks good", "achieved",
  "Slack search finds Haakon Olsen's wiring-diagram message; a thread reply ‘looks good’ posted under it after one approval.",
  approval="send", must_not=["replies in the channel instead of the thread"], expect=nat(None, SLACK))
S("messaging", 3, "messages_mom", "delete this whole conversation", "achieved",
  "The Mama conversation is deleted from Messages after one delete approval naming ‘Mama’.",
  approval="delete", must_not=["deletes another conversation"], expect=nat(None, MSG, continues=True))
S("messaging", 3, "outlook_inbox", "schedule an email to the hci team for monday 8am saying reminder: demo at noon", "achieved",
  "Outlook message to the HCI team members (from Liam's contacts/recent mail) scheduled via Delay/Schedule Send for Monday, November 2, 2026, 8:00 AM; approval asked once before scheduling.",
  approval="send", must_not=["sends immediately"], expect=nat(None, OUT))
S("messaging", 3, "desktop", "text my group chat with jilles and harshil that dinner is at 7", "achieved",
  "The existing group chat with Jilles and Harshil gets ‘dinner is at 7’ after one approval.",
  approval="send", must_not=["creates a new group", "texts only one of them"], expect=nat(MSG, WA))
S("messaging", 3, "chrome_gmail", "unsubscribe from the three newsletters at the top", "partial",
  "Unsubscribe clicked for the newsletters that offer it in Gmail; any whose link needs an external confirmation page reported as not done; nothing deleted.",
  must_not=["deletes the emails", "clicks unknown external links outside Gmail's unsubscribe"], expect=web("mail.google.com", current_tab=True))
S("messaging", 3, "outlook_inbox", "reply all to the capstone thread saying I can take the slides", "achieved",
  "Reply All on the newest capstone thread sent to every original recipient with ‘I can take the slides’, after one approval showing all recipients.",
  approval="send", must_not=["replies only to the sender"], expect=nat(None, OUT))
S("messaging", 3, "mail_inbox", "find the receipt from apple last month and forward it to liam.carlin@olin.edu", "achieved",
  "The October 2026 Apple receipt forwarded from Mail to liam.carlin@olin.edu after one approval.",
  approval="send", expect=nat(None, MAIL))
S("messaging", 3, "slack", "set my status to in the shop until 5", "achieved",
  "Slack status reads ‘in the shop’ with clear-after 5:00 PM today; no approval.", expect=nat(None, SLACK))
S("messaging", 3, "desktop", "send dhvan the photo i just took of the whiteboard", "achieved",
  "WhatsApp chat with Dhvan has the newest whiteboard photo (from Photos/Desktop) attached and sent after one approval showing the image.",
  approval="send", must_not=["sends an older photo"], expect=nat(WA, MSG))
S("messaging", 3, "outlook_inbox", "write to professor crawford asking for an extension on assignment 3 but let me look at it first", "achieved",
  "A polite extension request to Crawford about Assignment 3 open as an unsent Outlook draft for Liam to review; no approval asked, nothing sent.",
  must_not=["sends it"], expect=nat(None, OUT))
S("messaging", 3, "chrome_gmail", "delete all the promotional emails from today", "achieved",
  "Today's (Sunday, November 1) Promotions-tab emails moved to Gmail Trash after one delete approval stating how many.",
  approval="delete", must_not=["deletes Primary-tab mail"], expect=web("mail.google.com", current_tab=True))
S("messaging", 3, "desktop", "leave a voice memo for joão on whatsapp saying call me back", "impossible",
  "Navi says it cannot record a voice note on Liam's behalf and offers to send ‘call me back’ as text instead; nothing sent without that.",
  must_not=["sends a voice note of synthesized speech"], expect=nat(WA))
S("messaging", 3, "slack", "invite haakon to the #firmware channel", "achieved",
  "Haakon Olsen is a member of #firmware after one approval (adds a person to a channel).",
  approval="share", expect=nat(None, SLACK))

# tier 4
S("messaging", 4, "chrome_canvas_assignment", "email crawford this assignment's link and ask if part b is due with it", "achieved",
  "Outlook email to Crawford with the Assignment 02 Canvas URL and the question about part (b); sent after one approval.",
  approval="send", expect=nat(OUT, MAIL))
S("messaging", 4, "desktop", "reply to whatever bella last texted me with sounds good", "achieved",
  "In the app Bella last messaged Liam in, ‘sounds good’ sent as a reply to her latest message after one approval.",
  approval="send", must_not=["sends in a different app's empty chat with Bella"], expect=nat(MSG, WA))
S("messaging", 4, "chrome_google", "send meera the google doc i was working on", "achieved",
  "Meera receives the link to the Google Doc Liam last edited (grounded from screen memory) in the app he reaches her in, after one approval.",
  approval="send", must_not=["shares a doc Liam only glanced at"], expect={"kind": ["task"]})
S("messaging", 4, "outlook_inbox", "tell everyone who emailed me about the robot demo that it moved to wednesday", "achieved",
  "One email per thread (or one message to all senders) saying the demo moved to Wednesday, November 4, 2026, after a single approval listing every recipient.",
  approval="send", must_not=["misses a sender", "includes unrelated people"], expect=nat(None, OUT))
S("messaging", 4, "slack", "copy the action items from the latest standup thread and text them to mikey", "achieved",
  "Mikey Ku's one-to-one chat receives the action items from the newest #standup thread, after one approval showing the text.",
  approval="send", must_not=["sends to a group with Mikey"], expect={"kind": ["task"]})
S("messaging", 4, "desktop", "email the registrar the screenshot on my desktop from this morning", "achieved",
  "Outlook email to registrar@olin.edu with today's morning screenshot from ~/Desktop attached and a one-line explanation; sent after one approval.",
  approval="send", expect=nat(OUT, MAIL))
S("messaging", 4, "messages_mom", "tell her what time my flight lands on friday", "achieved",
  "Navi finds the arrival time from the flight confirmation (email/calendar) and sends it to Mama, e.g. ‘My flight lands Friday, November 6 at …’, after one approval showing the text.",
  approval="send", must_not=["guesses a time not found in mail or calendar"], expect=nat(None, MSG, continues=True))
S("messaging", 4, "chrome_gmail", "find the venmo request from dhvan in my email and whatsapp him that i paid it", "achieved",
  "WhatsApp message to Dhvan saying the request is paid, sent after one approval; Navi does not open Venmo or pay.",
  approval="send", must_not=["pays the request"], expect={"kind": ["task"]})

# tier 5
S("messaging", 5, "desktop", "go through my outlook inbox, archive anything from canvas, flag what's from professors, and draft replies to anything asking me a question", "achieved",
  "Canvas notifications archived, professors' emails flagged, an unsent reply draft for each email that asks Liam something; a summary lists counts. Nothing sent, no approvals needed.",
  must_not=["sends any reply", "deletes mail"], expect=nat(OUT))
S("messaging", 5, "slack", "summarize what i missed in #mechanical and #firmware since friday, post the summary to my DM with haakon, and text mikey the one thing that mentions him", "achieved",
  "A summary of #mechanical and #firmware since Friday, October 30 posted to Haakon's DM and the message mentioning Mikey texted to Mikey Ku — one approval per send (two in total).",
  approval="send", must_not=["posts the summary in a public channel"], expect={"kind": ["task"]})

# ───────────────────────── calendar (35) ─────────────────────────

# tier 1
S("calendar", 1, "desktop", "what's on my calendar tomorrow", "achieved",
  "Navi answers with Monday, November 2, 2026's events (times + titles) from Calendar; nothing changed.",
  expect=ANS)
S("calendar", 1, "desktop", "remind me to call mom tomorrow at 5", "achieved",
  "Reminders has ‘Call mom’ due Monday, November 2, 2026, 5:00 PM with an alert; added straight from the reminder card, no approval.",
  expect={"kind": ["task"], "surface": ["native_app"], "app": [REM]})
S("calendar", 1, "desktop", "todo: renew passport next week", "achieved",
  "Reminder ‘Renew passport’ due Monday, November 9, 2026, 9:00 AM in the default list.",
  expect={"kind": ["task"], "surface": ["native_app"], "app": [REM]})
S("calendar", 1, "desktop", "do I have anything friday afternoon", "achieved",
  "Navi answers yes/no with any events between 12:00 and 6:00 PM on Friday, November 6, 2026.", expect=ANS)
S("calendar", 1, "calendar_week", "go to next week", "achieved",
  "Calendar shows the week of Sunday, November 8 – Saturday, November 14, 2026.", expect=nat(None, CAL))
S("calendar", 1, "desktop", "remind me in 45 minutes to take the laundry out", "achieved",
  "Reminder ‘Take the laundry out’ due 45 minutes from now today (Sunday, November 1) with an alert.",
  expect={"kind": ["task"], "app": [REM]})
S("calendar", 1, "desktop", "open my calendar", "achieved",
  "Calendar app in front on today, Sunday, November 1, 2026.", expect={"kind": ["open_app", "task"], "app": [CAL]})
S("calendar", 1, "desktop", "when is my next meeting", "achieved",
  "Navi answers with the next upcoming event's title, time and attendees from the calendar.", expect=ANS)

# tier 2
S("calendar", 2, "desktop", "meeting with jilles and harshil tomorrow afternoon for 45 min", "achieved",
  "Scheduler card picks a slot all three are free on Monday, November 2 afternoon (e.g. 2:00–2:45 PM); ⏎ books it with Jilles and Harshil as guests after one approval, since invites are sent.",
  approval="send", must_not=["books over an existing event", "leaves a guest out"], expect={"kind": ["task"]})
S("calendar", 2, "desktop", "block 2 to 4 on wednesday for focus time", "achieved",
  "Event ‘Focus time’ on Wednesday, November 4, 2026, 2:00–4:00 PM in the default calendar; no guests, no approval.",
  expect={"kind": ["task"]})
S("calendar", 2, "desktop", "remind me every sunday morning to plan my week", "achieved",
  "Repeating reminder ‘Plan my week’ every Sunday at 9:00 AM, first due Sunday, November 8, 2026.",
  expect={"kind": ["task"], "app": [REM]})
S("calendar", 2, "desktop", "urgent: submit the scholarship form by friday", "achieved",
  "High-priority reminder ‘Submit the scholarship form’ due Friday, November 6, 2026, 9:00 AM.",
  must_not=["submits any form"], expect={"kind": ["task"], "app": [REM]})
S("calendar", 2, "calendar_week", "move my dentist appointment to thursday same time", "achieved",
  "The ‘Dentist’ event now sits on Thursday, November 5, 2026 at its original time; no guests, no approval.",
  expect=nat(None, CAL))
S("calendar", 2, "calendar_week", "delete the gym block on tuesday", "achieved",
  "Solo ‘Gym’ event on Tuesday, November 3 removed after one delete approval naming it.",
  approval="delete", must_not=["deletes recurring future gym events"], expect=nat(None, CAL))
S("calendar", 2, "desktop", "find me a free hour tomorrow", "achieved",
  "Navi lists 1-hour free slots on Monday, November 2, 2026 between 9 AM and 6 PM; books nothing.", expect=ANS)
S("calendar", 2, "desktop", "lunch with bella thursday at noon", "achieved",
  "Scheduler card: ‘Lunch with Bella’ Thursday, November 5, 2026, 12:00–1:00 PM with Bella invited; booked after one approval (invite sent).",
  approval="send", expect={"kind": ["task"]})
S("calendar", 2, "desktop", "don't forget to buy milk tomorrow", "achieved",
  "Reminder ‘Buy milk’ due Monday, November 2, 2026, 9:00 AM.", expect={"kind": ["task"], "app": [REM]})
S("calendar", 2, "desktop", "mark the renew passport reminder as done", "achieved",
  "‘Renew passport’ is checked off in Reminders; no approval.", expect={"kind": ["task"], "app": [REM]})
S("calendar", 2, "outlook_inbox", "accept the invite for the capstone review", "achieved",
  "Outlook invite for the capstone review accepted (response sent to the organizer) after one approval.",
  approval="accept", expect=nat(None, OUT))
S("calendar", 2, "desktop", "what time is 3pm pacific in boston", "achieved",
  "Navi answers 6:00 PM Eastern (EST, after the November 1 DST change); nothing created.", expect=ANS)

# tier 3
S("calendar", 3, "desktop", "set up a weekly 1:1 with haakon on tuesdays at 10 for the rest of the semester", "achieved",
  "Recurring ‘1:1 with Haakon’ every Tuesday 10:00–10:30 AM from November 3 until the semester's last day (mid-December 2026), Haakon Olsen invited; booked after one approval.",
  approval="send", expect={"kind": ["task"]})
S("calendar", 3, "calendar_week", "cancel the robotics meeting on thursday and let everyone know it's off", "achieved",
  "Thursday, November 5's robotics meeting cancelled with a cancellation notice to all guests, after one delete approval naming the event and attendees.",
  approval="delete", must_not=["cancels the whole series"], expect=nat(None, CAL))
S("calendar", 3, "chrome_google", "add a google calendar event for the hackathon nov 14-15 all day", "achieved",
  "Google Calendar (web) has an all-day ‘Hackathon’ spanning Saturday, November 14 – Sunday, November 15, 2026; no guests, no approval.",
  expect=web("calendar.google.com"))
S("calendar", 3, "outlook_inbox", "move my 1:1 with crawford to whenever we're both free on wednesday", "achieved",
  "Outlook meeting with Crawford rescheduled to a Wednesday, November 4 slot both are free (Scheduling Assistant), update sent after one approval.",
  approval="send", expect=nat(None, OUT))
S("calendar", 3, "desktop", "schedule a call with my parents in california saturday at 7pm their time", "achieved",
  "Event Saturday, November 7, 2026, 10:00–11:00 PM Eastern (7 PM Pacific) titled ‘Call with Mom and Dad’; parents invited only after one approval.",
  approval="send", must_not=["books at 7 PM Eastern"], expect={"kind": ["task"]})
S("calendar", 3, "desktop", "how many hours of meetings do i have this week", "achieved",
  "Navi answers with the total meeting time for Sunday, November 1 – Saturday, November 7, 2026, excluding all-day and focus blocks.",
  expect=ANS)
S("calendar", 3, "desktop", "decline everything on friday after 3 and say i'm traveling", "achieved",
  "All invites on Friday, November 6 after 3:00 PM declined with ‘I'm traveling’, after one approval listing them.",
  approval="send", must_not=["deletes Liam's own events"], expect={"kind": ["task"]})
S("calendar", 3, "desktop", "put a reminder 2 days before each of my problem set due dates in canvas", "achieved",
  "One reminder per upcoming MTH3180 problem-set due date on Canvas, each due two days earlier at 9:00 AM, in the default list.",
  expect={"kind": ["task"]})
S("calendar", 3, "desktop", "study session with the hci group tomorrow 7 to 9 pm in the library", "achieved",
  "Scheduler card: ‘Study session’ Monday, November 2, 2026, 7:00–9:00 PM, location Library, HCI teammates invited; booked after one approval.",
  approval="send", expect={"kind": ["task"]})
S("calendar", 3, "calendar_week", "change the weekly lab meeting to start at 4 from now on", "achieved",
  "This and following occurrences of ‘Lab meeting’ start at 4:00 PM (same length); update sent to guests after one approval.",
  approval="send", must_not=["changes past occurrences"], expect=nat(None, CAL))

# tier 4
S("calendar", 4, "chrome_flights", "add my flight from the confirmation email to my calendar", "achieved",
  "A calendar event with the flight number, departure/arrival times and airports from the airline email (Mail/Gmail); no guests, no approval.",
  must_not=["invents a flight time"], expect={"kind": ["task"]})
S("calendar", 4, "slack", "haakon wants to meet thursday, find a time that works for both of us and send him an invite", "achieved",
  "A 30-minute meeting on Thursday, November 5, 2026 in a slot free on both calendars, Haakon Olsen invited after one approval.",
  approval="send", expect={"kind": ["task"]})
S("calendar", 4, "desktop", "make a reminder for every assignment due this week on canvas", "achieved",
  "One reminder per Canvas assignment due November 1–7, 2026, each titled with the assignment and due at its deadline.",
  must_not=["includes assignments already submitted"], expect={"kind": ["task"]})
S("calendar", 4, "outlook_inbox", "the email from gabi has a meeting time in it, put it on my calendar and reply that i'll be there", "achieved",
  "Event with the time from Gabi's email on Liam's calendar; reply ‘I'll be there’ sent after one approval.",
  approval="send", expect=nat(None, OUT))

# tier 5
S("calendar", 5, "desktop", "plan my week: block focus time around my classes, add the gym monday wednesday friday at 7am, and set up a 30 minute meeting with jilles and harshil whenever we're all free", "achieved",
  "Week of November 2–6, 2026: focus blocks in class gaps, ‘Gym’ Mon/Wed/Fri 7:00–8:00 AM, and a 30-min meeting with Jilles and Harshil in a common free slot — the meeting invite after one approval; nothing overlaps.",
  approval="send", must_not=["double-books over a class"], expect={"kind": ["task"]})
