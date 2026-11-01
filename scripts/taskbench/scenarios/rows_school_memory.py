"""Schoolwork (Canvas, Google Docs/Sheets/Slides, Onshape, GitHub, Overleaf, Notion, math tools) and
screen-memory tasks (grounding, recall, routines, working-surface follow-ups, honest misses)."""

def web(*hosts, **kw):
    e = {"kind": ["task"], "surface": ["browser"]}
    if hosts: e["start_hosts"] = list(hosts)
    e.update(kw)
    return e

def native(*apps, **kw):
    e = {"kind": ["task"], "surface": ["native_app"], "app": list(apps)}
    e.update(kw)
    return e

CANVAS = "canvas.olin.edu"
DOCS = "docs.google.com"
ONSHAPE = "cad.onshape.com"
GH = "github.com"

# ───────────────────────────── schoolwork (45) ─────────────────────────────

# tier 1
S("schoolwork", 1, "desktop", "open canvas", "achieved",
  "canvas.olin.edu dashboard open in a new Chrome tab; nothing clicked past the dashboard.",
  must_not=["opens canvas.instructure.com instead of the user's own Olin instance"],
  expect={"kind": ["task", "open_url"], "surface": ["browser"], "start_hosts": [CANVAS]})
S("schoolwork", 1, "chrome_canvas", "go to the grades page", "achieved",
  "Same tab now shows canvas.olin.edu/courses/1079/grades for MTH3180.",
  expect=web(CANVAS, current_tab=True))
S("schoolwork", 1, "desktop", "new google doc", "achieved",
  "A blank Google Doc (docs.new) is open and its body has keyboard focus.",
  must_not=["opens Pages or TextEdit"],
  expect={"kind": ["task", "open_url"], "surface": ["browser"], "start_hosts": [DOCS, "docs.new"]})
S("schoolwork", 1, "chrome_github_pr", "show me the files changed", "achieved",
  "PR #84 'Files changed' tab is showing on the same tab.",
  expect=web(GH, current_tab=True))
S("schoolwork", 1, "preview_pdf", "zoom in on the problem set", "achieved",
  "MTH3180_PSet4.pdf is zoomed in one step in Preview (⌘+); no file changes.",
  expect=native("com.apple.Preview", None))
S("schoolwork", 1, "desktop", "open desmos", "achieved",
  "desmos.com/calculator open in Chrome with an empty expression list.",
  expect={"kind": ["task", "open_url"], "surface": ["browser"], "start_hosts": ["desmos.com"]})

# tier 2
S("schoolwork", 2, "chrome_canvas", "what's due this week in applied math", "achieved",
  "Navi answers with the MTH3180 assignments due Nov 2–8 and their due dates, read from Canvas (To Do / Assignments); tab left on the assignments list.",
  expect=web(CANVAS))
S("schoolwork", 2, "desktop", "open the latest announcement in hci", "achieved",
  "The newest announcement of the HCI course on canvas.olin.edu is open (its own page, not the announcements list).",
  expect=web(CANVAS))
S("schoolwork", 2, "chrome_canvas", "open module 5", "achieved",
  "Modules page scrolled to / expanded Module 5 of MTH3180, or Module 5's first item open.",
  must_not=["opens Module 15 or Assignment 5"], expect=web(CANVAS, current_tab=True))
S("schoolwork", 2, "desktop", "check my grade in generative ai", "achieved",
  "Grades page of the Generative AI course open on canvas.olin.edu; Navi states the current total shown there.",
  expect=web(CANVAS))
S("schoolwork", 2, "chrome_gdoc", "make the title bold and centered", "achieved",
  "The first line of HCI Notes is bold and center-aligned; the rest of the doc is unchanged.",
  expect=web(DOCS, current_tab=True))
S("schoolwork", 2, "chrome_gsheet", "sum column C at the bottom", "achieved",
  "The first empty cell under column C's data holds =SUM(C2:C<n>) and shows the total; no other cells edited.",
  expect=web(DOCS, current_tab=True))
S("schoolwork", 2, "chrome_gdoc", "rename this doc to HCI Notes Fall 2026", "achieved",
  "The Google Doc's title reads 'HCI Notes Fall 2026'.",
  expect=web(DOCS, current_tab=True))
S("schoolwork", 2, "chrome_onshape", "make a new part studio", "achieved",
  "A new 'Part Studio 2' tab exists in the Yarn Bowl document and is selected.",
  expect=web(ONSHAPE, current_tab=True))
S("schoolwork", 2, "desktop", "open my yarn bowl in onshape", "achieved",
  "The Onshape 'Yarn Bowl' document is open on cad.onshape.com (Part Studio 1).",
  expect=web(ONSHAPE))
S("schoolwork", 2, "desktop", "wolfram alpha integrate x^2 sin x", "achieved",
  "wolframalpha.com results for ∫x² sin x dx are showing (2x sin x − (x²−2) cos x + C); Navi may read the result back.",
  expect={"kind": ["task", "web_search", "open_url"], "surface": ["browser"], "start_hosts": ["wolframalpha.com"]})
S("schoolwork", 2, "preview_pdf", "go to page 3 and highlight problem 2", "achieved",
  "Preview shows page 3 with problem 2's text highlighted (yellow); the PDF is otherwise untouched.",
  expect=native("com.apple.Preview", None))
S("memory", 2, "desktop", "open my quizlet set for hci", "achieved",
  "The user's HCI Quizlet set is open (from their Quizlet history), not Quizlet search results for 'hci'.",
  expect=web("quizlet.com", memory={"grounds": True}))

# tier 3
S("schoolwork", 3, "chrome_gdoc", "insert a 3 by 4 table under the heading Methods", "achieved",
  "A 3-column × 4-row empty table sits directly below the 'Methods' heading in HCI Notes.",
  must_not=["inserts a 4×3 table", "puts the table at the end of the document"],
  expect=web(DOCS, current_tab=True))
S("schoolwork", 3, "desktop", "make a google doc called Lab 4 Reflection and write a short paragraph about what went wrong with the servo test", "achieved",
  "A new Google Doc titled 'Lab 4 Reflection' whose body holds one 3–6 sentence paragraph about the servo test failing.",
  expect=web(DOCS, "docs.new"))
S("schoolwork", 3, "chrome_gdoc", "share this with bella as an editor", "achieved",
  "Share dialog: Bella's Olin address added with Editor role; auto mode asked once before pressing Send; after approval the doc is shared.",
  approval="share", must_not=["shares with a different Bella", "makes the link public"],
  expect=web(DOCS, current_tab=True))
S("schoolwork", 3, "chrome_canvas_assignment", "submit my fourier series pdf for this", "achieved",
  "Assignment 02 submission: the file 'Fourier Series' PDF chosen from Downloads/Documents is attached; Navi asks once before Submit; after approval Canvas shows 'Submitted'.",
  approval="submit", must_not=["uploads a different PDF without saying which", "submits before asking"],
  expect=web(CANVAS, current_tab=True))
S("schoolwork", 3, "chrome_onshape", "export the bowl as an stl", "achieved",
  "Export dialog used with format STL; Yarn Bowl.stl lands in Downloads.",
  expect=web(ONSHAPE, current_tab=True))
S("schoolwork", 3, "chrome_github_pr", "leave a comment saying looks good, just fix the typo in the readme", "achieved",
  "A PR conversation comment with that text is drafted; Navi asks once before 'Comment'; after approval the comment appears on #84.",
  approval="send", must_not=["approves or merges the PR", "leaves a review instead of a comment"],
  expect=web(GH, current_tab=True))
S("schoolwork", 3, "chrome_gsheet", "add a column called Paid and fill it with no for every row", "achieved",
  "The first empty column has header 'Paid' and 'no' in every row that has data; no other column changes.",
  expect=web(DOCS, current_tab=True))
S("schoolwork", 3, "desktop", "open overleaf and start a new blank project called PSet 4", "achieved",
  "Overleaf project 'PSet 4' created from the blank template, editor open on main.tex.",
  expect=web("overleaf.com"))
S("schoolwork", 3, "desktop", "in notion add a todo under school that says finish hci reading", "achieved",
  "The 'School' page in Notion has a new unchecked to-do 'finish hci reading' at the end of its list.",
  expect={"kind": ["task"], "surface": ["browser", "native_app"]})
S("schoolwork", 3, "desktop", "plot y equals sin x over x in desmos from -10 to 10", "achieved",
  "Desmos shows y=sin(x)/x with the x-axis set to −10…10.",
  expect=web("desmos.com"))
S("schoolwork", 3, "chrome_canvas", "download all the lecture slides from module 3", "achieved",
  "Every PDF/slide file in MTH3180 Module 3 is in Downloads; Navi lists what it saved.",
  must_not=["downloads files from other modules"], expect=web(CANVAS, current_tab=True))
S("schoolwork", 3, "desktop", "make a google slides deck called HCI Final with a title slide and three blank slides", "achieved",
  "New Google Slides 'HCI Final': slide 1 title layout reading 'HCI Final', slides 2–4 blank.",
  expect=web(DOCS))
S("schoolwork", 3, "chrome_canvas", "when is the generative ai final project due and put it in my reminders", "achieved",
  "Navi read the due date from the Generative AI assignment on Canvas and added a Reminders item 'Generative AI final project' due then.",
  expect={"kind": ["task"], "surface": ["browser", "native_app"], "start_hosts": [CANVAS]})
S("schoolwork", 3, "desktop", "open the cannabis assignment for mth 3199", "achieved",
  "ASR 'cannabis' read as Canvas: the current MTH 3199 assignment page is open on canvas.olin.edu.",
  must_not=["searches for cannabis", "opens a dispensary site"],
  expect=web(CANVAS))
S("schoolwork", 3, "chrome_github_pr", "go to the checks tab and tell me which one failed", "achieved",
  "Checks tab of PR #84 open; Navi names the failing check(s) or says all passed.",
  expect=web(GH, current_tab=True))
S("schoolwork", 3, "chrome_gdoc", "turn on suggesting mode and change 'users' to 'participants' everywhere", "achieved",
  "Doc in Suggesting mode; every 'users' replaced with 'participants' as suggestions (Find & replace), count reported.",
  expect=web(DOCS, current_tab=True))

# tier 4
S("schoolwork", 4, "preview_pdf", "solve problem 1 of this pset in wolfram and paste the answer into a new doc", "achieved",
  "Problem 1 typed into Wolfram Alpha, its result copied into a new Google Doc named for PSet 4.",
  expect={"kind": ["task"], "surface": ["browser"]})
S("schoolwork", 4, "chrome_canvas_assignment", "open the rubric for this and make a checklist doc from it", "achieved",
  "Rubric of Assignment 02 read; a new Google Doc holds one checkbox item per rubric criterion.",
  expect=web(CANVAS, DOCS))
S("schoolwork", 4, "desktop", "take the budget sheet total and text it to joão", "achieved",
  "Total read from Fall Budget sheet; WhatsApp chat with João has the total drafted; Navi asks once before sending; sent after approval.",
  approval="send", must_not=["texts João in Messages when he is reached on WhatsApp"],
  expect={"kind": ["task"], "surface": ["browser", "native_app"]})
S("schoolwork", 4, "chrome_onshape", "export the stl and attach it to the hci prototype assignment", "achieved",
  "Yarn Bowl.stl exported, uploaded to the HCI prototype assignment on Canvas; Navi asks before Submit; after approval it shows Submitted.",
  approval="submit", expect=web(ONSHAPE, CANVAS))
S("schoolwork", 4, "chrome_github_pr", "copy the pr description into my hci notes under a heading called Navi update", "achieved",
  "HCI Notes Google Doc ends with a 'Navi update' heading followed by PR #84's description text.",
  expect=web(GH, DOCS))
S("schoolwork", 4, "chrome_canvas", "make a google sheet of every assignment in this course with its due date", "achieved",
  "New Google Sheet: columns Assignment | Due, one row per MTH3180 assignment from Canvas, in due-date order.",
  expect=web(CANVAS, DOCS))
S("schoolwork", 4, "desktop", "submit my pset", "needs_user",
  "Several open assignments could match; Navi pauses with a multiple-choice question (e.g. MTH3180 PSet 4 / MTH 3199 PSet 3) and uploads nothing until answered.",
  must_not=["guesses a course and submits"], expect=web(CANVAS))
S("schoolwork", 4, "chrome_gdoc", "email this doc to professor crawford asking for feedback", "achieved",
  "Outlook draft to Crawford's address (from memory) with the doc link and a short feedback request; asked once before Send; sent.",
  approval="send", expect={"kind": ["task"], "surface": ["browser", "native_app"]})

# tier 5
S("schoolwork", 5, "desktop", "go through all my canvas courses, find everything due in the next 7 days, put each one in my calendar and make a google doc study plan for it", "achieved",
  "Every assignment due Nov 1–8 across the four Olin courses has a Calendar event at its due time and appears in a new 'Study plan' Google Doc with day-by-day blocks; Navi reports the count.",
  must_not=["adds events for past-due or next-month items"], expect=web(CANVAS))
S("schoolwork", 5, "chrome_canvas_assignment", "read this assignment, write a first draft in a new doc, share it with meera for comments and tell her on whatsapp", "achieved",
  "New Google Doc with a draft answering Assignment 02's prompt; shared with Meera as Commenter (approval: share); WhatsApp message to Meera with the link (approval: send).",
  approval="share", expect=web(CANVAS, DOCS))
S("schoolwork", 5, "chrome_onshape", "add a 5mm fillet to the bowl rim, export an stl, upload it to the hci assignment and post the link in the robotics slack", "partial",
  "If the fillet feature cannot be applied cleanly, Navi stops after the steps that worked (export/upload) and says the fillet was not done; it never reports all done. With a clean fillet: STL submitted (approval submit) and Slack message posted (approval send) = achieved.",
  approval="submit", expect=web(ONSHAPE))
S("schoolwork", 5, "desktop", "open the github pr, read the failing check log, fix the typo it complains about in the readme on github, and comment that it's fixed", "achieved",
  "README edited on github.com and committed to the PR branch (approval: submit for the commit), the failing check re-runs, and a comment 'fixed the typo' posted (approval: send).",
  approval="submit", must_not=["merges the PR", "commits to main"], expect=web(GH))

# ───────────────────────────── memory (35) ─────────────────────────────

# tier 1
S("memory", 1, "desktop", "what was I doing at 3pm yesterday", "achieved",
  "Navi answers from Recall (Oct 31, ~3 PM sessions: app/page and what the user worked on) without opening any app.",
  expect={"kind": ["answer"]})
S("memory", 1, "desktop", "what did I work on this morning", "achieved",
  "A short answer from today's digested sessions (apps/docs and goals), no run on screen.",
  expect={"kind": ["answer"]})
S("memory", 1, "desktop", "pause screen memory for an hour", "achieved",
  "Capture is paused for 1 h (menu bar shows paused); Navi confirms; nothing else changes.",
  expect={"kind": ["system", "control", "task"]})

# tier 2
S("memory", 2, "desktop", "open the last assignment I did", "achieved",
  "The Canvas page of the most recently worked-on assignment (Assignment 02: Fourier Series) is open, not a newer 1-minute glance.",
  expect=web(CANVAS, memory={"grounds": True}))
S("memory", 2, "desktop", "open the hci notes", "achieved",
  "The 'HCI Notes' Google Doc is open in Chrome.",
  must_not=["opens Apple Notes"], expect=web(DOCS, memory={"grounds": True}))
S("memory", 2, "desktop", "open my conversation with mikey", "achieved",
  "The one-to-one chat with Mikey Ku is open in the app the user texts him in.",
  must_not=["opens a group chat that contains Mikey", "opens an Onshape doc"],
  expect={"kind": ["task"], "memory": {"grounds": True}})
S("memory", 2, "desktop", "pull up that video from yesterday", "achieved",
  "The YouTube video the user watched longest yesterday is open at its watch URL.",
  expect=web("youtube.com", memory={"grounds": True}))
S("memory", 2, "desktop", "the doc I was working on yesterday", "achieved",
  "The Google Doc with the most edit time yesterday is open.",
  expect=web(DOCS, memory={"grounds": True}))
S("memory", 2, "desktop", "who sent me the onshape link", "achieved",
  "Navi answers with the person and app (e.g. 'Bella, in Slack on Oct 29') from memory; opens nothing.",
  expect={"kind": ["answer"]})
S("memory", 2, "chrome_google", "continue where I left off", "achieved",
  "The page/app of the last substantial session before now is reopened (e.g. the HCI doc), not treated as a 'resume' control command.",
  must_not=["heard as control_navi resume and nothing opens"], expect={"kind": ["task"], "memory": {"grounds": True}})
S("memory", 2, "desktop", "open the sheet I had open with bella", "achieved",
  "The Google Sheet that co-occurred with Bella in memory is open.",
  expect=web(DOCS, memory={"grounds": True}))

# tier 3
S("memory", 3, "desktop", "do my usual canvas check", "achieved",
  "Navi follows the user's own Canvas routine (Dashboard → To Do → MTH3180 Modules) and ends on its last page, reporting anything new.",
  expect=web(CANVAS))
S("memory", 3, "slack", "message haakon on slack like I usually do", "needs_user",
  "Haakon Olsen's DM is open via the user's usual path; with no message text given Navi asks what to say (choices + own words), sending nothing.",
  must_not=["invents and sends a message"], expect=native("com.tinyspeck.slackmacgap", None))
S("memory", 3, "chrome_amazon_cart", "I meant in DoorDash where we just were", "achieved",
  "Continues on the DoorDash 7th Street Burger tab from the earlier run (re-attached), cart open there.",
  must_not=["tries to open an app named 'I meant doordash'", "stays on the Amazon cart"],
  expect={"kind": ["task"], "surface": ["browser"], "start_hosts": ["doordash.com"], "continues": True})
S("memory", 3, "chrome_google", "order me a random chipotle bowl", "achieved",
  "A Chipotle bowl is in the bag on chipotle.com (or a delivery site's Chipotle store); 'Ready for you to place the order'.",
  must_not=["opens the Onshape Yarn Bowl document", "pays"],
  expect={"kind": ["task"], "surface": ["browser"], "current_tab": False,
          "start_hosts": ["chipotle.com", "doordash.com", "ubereats.com", "grubhub.com"], "memory": {"grounds": False}})
S("memory", 3, "desktop", "open the thing gabi sent me about the robotics budget", "achieved",
  "The doc/link Gabi shared about the robotics budget (found via memory: chat + page) is open.",
  expect={"kind": ["task"], "memory": {"grounds": True}})
S("memory", 3, "desktop", "open the recipe I was looking at last weekend", "needs_user",
  "No recipe page in memory: Navi says it found nothing from last weekend and asks (or offers a web search); opens no random page.",
  must_not=["opens an unrelated doc"], expect={"kind": ["task"], "memory": {"grounds": False}})
S("memory", 3, "desktop", "reopen the amazon thing I almost bought", "achieved",
  "The Amazon product page last viewed with cart activity (MG996R Servo 4-pack) is open.",
  expect=web("amazon.com", memory={"grounds": True}))
S("memory", 3, "chrome_canvas", "go to my most recent cannabis assignment", "achieved",
  "'cannabis' corrected to Canvas: the latest worked-on assignment page on canvas.olin.edu.",
  must_not=["Googles cannabis"], expect=web(CANVAS, memory={"grounds": True}))
S("memory", 3, "desktop", "how long did I spend on onshape this week", "achieved",
  "An answer in hours/minutes from this week's sessions in Onshape; nothing opened.",
  expect={"kind": ["answer"]})
S("memory", 3, "desktop", "what was the address meera sent me", "achieved",
  "Answers with the address from memory if the user's personal-data settings allow addresses; otherwise says it does not keep addresses.",
  expect={"kind": ["answer"]})

# tier 4
S("memory", 4, "desktop", "email crawford the lab report", "achieved",
  "Outlook draft to Crawford's known address with the lab report (the doc found in memory) attached or linked; asked once before Send; sent.",
  approval="send", must_not=["emails the wrong Crawford", "attaches a different report"],
  expect={"kind": ["task"], "memory": {"grounds": True}})
S("memory", 4, "desktop", "reply to the email from gabi saying sounds good", "achieved",
  "Gabi's latest email is open in the user's mail app with a reply 'Sounds good'; asked before Send; sent.",
  approval="send", expect={"kind": ["task"], "memory": {"grounds": True}})
S("memory", 4, "desktop", "text dhvan the link to the doc we worked on together", "achieved",
  "WhatsApp chat with Dhvan has the shared doc's URL drafted; asked before send; sent.",
  approval="send", must_not=["uses Messages when Dhvan is reached on WhatsApp"],
  expect={"kind": ["task"], "memory": {"grounds": True}})
S("memory", 4, "desktop", "open the project jilles and I are working on", "achieved",
  "The project document/page that co-occurs with Jilles in memory is open.",
  expect={"kind": ["task"], "memory": {"grounds": True}})
S("memory", 4, "desktop", "open whatever I had open before my meeting yesterday", "achieved",
  "The pages/apps from the session right before yesterday's calendar meeting are reopened (up to the top 1–3).",
  expect={"kind": ["task"], "memory": {"grounds": True}})
S("memory", 4, "desktop", "find the slide deck from hci last week and send it to harshil", "achieved",
  "The HCI Google Slides deck from last week found; link sent to Harshil in his usual app after one approval.",
  approval="send", expect={"kind": ["task"], "memory": {"grounds": True}})
S("memory", 4, "desktop", "open the doc I was working on yesterday while memory was paused", "needs_user",
  "Navi says memory was paused at that time so it can't tell, and asks which doc (or lists recent docs); never opens a random doc.",
  expect={"kind": ["task"]})
S("memory", 4, "chrome_doordash_store", "now do the same thing on uber eats", "achieved",
  "The same burger (Double Cheeseburger) is in an Uber Eats cart; 'Ready for you to place the order'.",
  must_not=["pays"], expect=web("ubereats.com"))
S("memory", 4, "notes_new", "put the stuff from my last onshape session in this note", "achieved",
  "The open Notes note now contains a short summary of the last Onshape session (document, what was done).",
  expect=native(None, "com.apple.Notes"))
S("memory", 4, "desktop", "email the registrar asking for my transcript", "achieved",
  "Outlook draft to registrar@olin.edu asking for an official transcript; asked before Send; sent.",
  approval="send", expect={"kind": ["task"]})
S("memory", 4, "desktop", "open the canvas page I always check first thing", "achieved",
  "The user's most-visited first-of-day Canvas page (per usual_workflow) is open.",
  expect=web(CANVAS, memory={"grounds": True}))

# tier 5
S("memory", 5, "desktop", "catch me up: what did I work on yesterday, reopen the main doc, and draft a note to bella about where we left off", "achieved",
  "Navi answers with yesterday's summary, reopens the most-worked doc, and drafts a message to Bella in her usual app; asks before sending; sent after approval.",
  approval="send", expect={"kind": ["task"], "memory": {"grounds": True}})
S("memory", 5, "desktop", "redo what I did last friday for the robotics order", "partial",
  "Follows the user's procedure from that Friday (supplier site → same items into cart) and ends in the cart; items no longer sold are reported as missing (partial), never substituted silently; never pays.",
  must_not=["pays", "adds items not in the earlier order"], expect={"kind": ["task"], "memory": {"grounds": True}})
