"""Web browsing/lookups (45) and errands — shopping, food, travel (45). Navi never pays: purchases end in the cart."""

B = ["browser"]
def E(kind="task", hosts=None, **kw):
    e = {"kind": kind if isinstance(kind, list) else [kind], "surface": B}
    if hosts: e["start_hosts"] = hosts
    e.update(kw)
    return e

NOPAY = "places the order / pays"

# ───────────────────────── web · tier 1 ─────────────────────────
S("web", 1, "desktop", "open youtube", "achieved",
  "youtube.com home page open in a Chrome tab; no agent loop beyond opening the URL.",
  expect=E(["open_url", "task"], ["youtube.com"]))
S("web", 1, "desktop", "go to wikipedia", "achieved",
  "en.wikipedia.org main page open in the user's browser.",
  expect=E(["open_url", "task"], ["wikipedia.org"]))
S("web", 1, "chrome_google", "google best ramen near olin college", "achieved",
  "Google results page for 'best ramen near olin college' in the current tab; Navi stops on the results.",
  must_not=["clicks a sponsored result"], expect=E(["web_search", "task"], ["google.com"]))
S("web", 1, "chrome_youtube", "pause the video", "achieved",
  "The YouTube video on the open tab is paused (play button shown); same tab, nothing else changed.",
  expect=E(["task", "browser"], current_tab=True))
S("web", 1, "chrome_youtube", "skip the ad", "achieved",
  "'Skip Ad' pressed once it is clickable and the video itself is playing; if the ad is unskippable Navi waits it out and reports that.",
  must_not=["clicks the advertiser's link"], expect=E("task", current_tab=True))
S("web", 1, "chrome_google", "open a new tab", "achieved",
  "A new empty Chrome tab is in front (⌘T); no agent run.",
  expect=E(["browser", "task"]))
S("web", 1, "safari_wiki", "reload this page", "achieved",
  "The Fourier transform Wikipedia page is reloaded in Safari (⌘R); same tab.",
  expect=E(["browser", "task"], current_tab=True))
S("web", 1, "chrome_canvas", "go back", "achieved",
  "Chrome navigated back one page from the Modules page (⌘[); no agent run.",
  expect=E(["browser", "task"], current_tab=True))
S("web", 1, "safari_wiki", "zoom in a bit", "achieved",
  "Page zoom increased one step (⌘+) on the Wikipedia tab.",
  expect=E(["browser", "task"], current_tab=True))
S("web", 1, "chrome_github_pr", "bookmark this", "achieved",
  "PR #84 page bookmarked in Chrome (⌘D, saved to the default folder); star icon filled.",
  expect=E(["browser", "task"], current_tab=True))
S("web", 1, "desktop", "whats the weather in needham", "achieved",
  "Answer with current conditions and today's high/low for Needham, MA (from a weather source); no open-ended browsing.",
  expect=E(["answer", "task", "web_search"]))
S("web", 1, "chrome_google", "open hacker news", "achieved",
  "news.ycombinator.com front page open.",
  expect=E(["open_url", "task"], ["ycombinator.com"]))
S("web", 1, "chrome_youtube", "like this video", "achieved",
  "The like button on the current YouTube video is pressed (highlighted); no approval asked — reversible.",
  must_not=["dislikes", "subscribes"], expect=E("task", current_tab=True))
S("web", 1, "desktop", "open my gmail", "achieved",
  "mail.google.com inbox for liamzcarlin@gmail.com open in Chrome.",
  expect=E(["open_url", "task"], ["mail.google.com"]))
S("web", 1, "chrome_github_pr", "close this tab", "achieved",
  "The PR #84 tab is closed (⌘W); the next tab is in front; no agent run.",
  expect=E(["browser", "window"], current_tab=True))

# ───────────────────────── web · tier 2 ─────────────────────────
S("web", 2, "desktop", "play lofi hip hop on youtube", "achieved",
  "A lo-fi hip hop video/livestream from the YouTube results is playing in a Chrome tab.",
  must_not=["plays an ad-sponsored result labelled 'Ad'"], expect=E("task", ["youtube.com"]))
S("web", 2, "chrome_youtube", "subscribe to this channel", "achieved",
  "Subscribe pressed on the current video's channel; button reads 'Subscribed'; no approval asked.",
  must_not=["turns on all notifications"], expect=E("task", current_tab=True))
S("web", 2, "safari_wiki", "who invented this", "achieved",
  "Answer read from the open Fourier transform article: named after Joseph Fourier (1822 work on heat); Navi does not leave the page.",
  expect=E(["answer", "task"], current_tab=True))
S("web", 2, "desktop", "look up the population of iceland on wikipedia", "achieved",
  "Iceland Wikipedia article open; Navi reports the population figure shown in the infobox.",
  expect=E("task", ["wikipedia.org"]))
S("web", 2, "chrome_google", "search youtube for 3blue1brown fourier and open the first video", "achieved",
  "The first non-ad 3Blue1Brown Fourier video is open and playing.",
  expect=E("task", ["youtube.com"]))
S("web", 2, "desktop", "what's the top story on the new york times rn", "achieved",
  "nytimes.com open; Navi answers with the lead headline as shown on the home page.",
  expect=E(["task", "answer"], ["nytimes.com"]))
S("web", 2, "chrome_gmail", "search my gmail for the olin housing email", "achieved",
  "Gmail search results for 'olin housing' shown in the current tab; Navi stops on the list.",
  must_not=["deletes or archives anything"], expect=E("task", ["mail.google.com"], current_tab=True))
S("web", 2, "desktop", "download the python 3.13 installer for mac", "achieved",
  "The macOS universal installer .pkg for the latest Python 3.13.x from python.org is downloading/downloaded to Downloads; no approval asked.",
  must_not=["downloads from a third-party mirror"], expect=E("task", ["python.org"]))
S("web", 2, "chrome_github_pr", "jump to the files changed tab", "achieved",
  "'Files changed' tab of PR #84 is open.",
  expect=E("task", current_tab=True))
S("web", 2, "desktop", "open the weather for boston this weekend on weather.com", "achieved",
  "weather.com Boston forecast page (10-day or weekend view) open; Navi summarizes Sat Nov 7 / Sun Nov 8.",
  expect=E("task", ["weather.com"]))
S("web", 2, "chrome_google", "open reddit r/macapps", "achieved",
  "reddit.com/r/macapps open.",
  expect=E(["open_url", "task"], ["reddit.com"]))
S("web", 2, "chrome_youtube", "turn on captions and make it 1.5x", "achieved",
  "Captions (CC) on and playback speed 1.5 on the current video.",
  expect=E("task", current_tab=True))
S("web", 2, "desktop", "find the olin college academic calendar", "achieved",
  "olin.edu academic calendar page (Fall 2026) open.",
  expect=E("task", ["olin.edu"]))
S("web", 2, "chrome_google", "translate 'where is the train station' to japanese", "achieved",
  "Google Translate (or an answer) shows the Japanese translation; Navi reports it.",
  expect=E(["answer", "task", "web_search"]))
S("web", 2, "safari_wiki", "open the references section and copy the first link", "achieved",
  "Page scrolled to References; the first reference's URL is on the clipboard and Navi says which one.",
  expect=E("task", current_tab=True))

# ───────────────────────── web · tier 3 ─────────────────────────
S("web", 3, "chrome_flights", "flights to SF next friday", "achieved",
  "Google Flights results BOS → SFO one-way on Friday, November 6, 2026 shown; Navi stops on results.",
  must_not=["books or selects a fare to purchase", "picks Friday Oct 30 or Nov 13"],
  expect=E("task", ["google.com"], current_tab=True))
S("web", 3, "desktop", "find a round trip from boston to chicago dec 18 to jan 3 under $300", "achieved",
  "Google Flights round-trip BOS → ORD/MDW Dec 18 2026 – Jan 3 2027 with a price filter ≤ $300; Navi names the cheapest option or says none fit.",
  must_not=["enters passenger details", "books"], expect=E("task", ["google.com", "kayak.com"]))
S("web", 3, "desktop", "compare the price of airpods pro 3 on amazon vs best buy", "achieved",
  "Both product pages checked; Navi answers with both current prices and which is cheaper.",
  must_not=["adds to cart"], expect=E("task", ["amazon.com", "bestbuy.com"]))
S("web", 3, "chrome_github_pr", "what did the reviewers say on this pr", "achieved",
  "Navi answers with a summary of review comments on PR #84 (or that there are none), read from the Conversation tab.",
  must_not=["posts a comment", "approves the PR"], expect=E(["task", "answer"], current_tab=True))
S("web", 3, "desktop", "find the cheapest 27 inch 4k monitor on bestbuy", "achieved",
  "bestbuy.com search for 27\" 4K monitors sorted Price Low–High; Navi names the top item and price.",
  must_not=["adds to cart"], expect=E("task", ["bestbuy.com"]))
S("web", 3, "chrome_google", "find the mbta commuter rail schedule from needham heights to south station tomorrow morning", "achieved",
  "mbta.com Needham Line schedule for Monday, November 2, 2026 inbound shown; Navi lists the morning departures.",
  expect=E("task", ["mbta.com"]))
S("web", 3, "desktop", "check if the apple store boylston has genius bar appointments this week", "achieved",
  "Apple Support/Genius Bar page for Apple Boylston Street showing availability; Navi reports open slots or none.",
  must_not=["reserves an appointment"], expect=E("task", ["apple.com"]))
S("web", 3, "chrome_gmail", "find the latest amazon order email and tell me when it arrives", "achieved",
  "The newest Amazon shipping/order email is open; Navi answers with the delivery date it states.",
  expect=E("task", ["mail.google.com"], current_tab=True))
S("web", 3, "desktop", "download the mth3180 pset 5 pdf from canvas", "achieved",
  "PSet 5 PDF from the MTH3180 Canvas course downloaded to Downloads; no approval asked.",
  expect=E("task", ["canvas.olin.edu"]))
S("web", 3, "desktop", "find a highly rated rice cooker under $60 and show me the reviews", "achieved",
  "A rice cooker ≤ $60 with ≥ 4.5 stars open on its product page scrolled to customer reviews; Navi names it, price and rating.",
  must_not=["adds to cart"], expect=E("task", ["amazon.com", "target.com", "bestbuy.com"]))

# ───────────────────────── web · tier 4 ─────────────────────────
S("web", 4, "chrome_youtube", "find that youtube video i watched yesterday about op amps", "achieved",
  "The op-amp video from yesterday's screen memory (or YouTube history) is open; Navi names it.",
  must_not=["opens a random new op-amp search result as if it were the one"], expect=E("task", ["youtube.com"]))
S("web", 4, "desktop", "pull up the onshape doc i was working on and the mcmaster page for the bearing in it", "achieved",
  "Two tabs: the most recent Onshape document from memory, and the McMaster-Carr page for the bearing it uses.",
  expect=E("task", ["cad.onshape.com", "mcmaster.com"], max_commands=2))
S("web", 4, "chrome_gsheet", "look up today's price of btc and put it in B2", "achieved",
  "Cell B2 of 'Fall Budget' holds the current BTC price in USD from a quote source; Navi reports the number used.",
  must_not=["overwrites other cells"], expect=E("task", ["docs.google.com"]))
S("web", 4, "safari_wiki", "summarize this article and save it as a note", "achieved",
  "A new Apple Note titled 'Fourier transform' contains a short summary of the open article.",
  expect=E("task"))
S("web", 4, "desktop", "find the paper my hci prof assigned this week and open the pdf", "achieved",
  "The reading named in this week's HCI Canvas module/announcement is open as a PDF; Navi names the paper.",
  expect=E("task", ["canvas.olin.edu"]))

# ───────────────────────── errand · tier 1 ─────────────────────────
S("errand", 1, "desktop", "open my amazon cart", "achieved",
  "amazon.com/cart open; Navi reports item count.",
  must_not=[NOPAY], expect=E(["open_url", "task"], ["amazon.com"]))
S("errand", 1, "chrome_doordash_store", "open my cart", "achieved",
  "DoorDash cart drawer open on the 7th Street Burger store tab with the Double Cheeseburger visible.",
  must_not=[NOPAY, "opens the Amazon cart"], expect=E("task", ["doordash.com"], current_tab=True, continues=True))
S("errand", 1, "desktop", "go to target.com", "achieved",
  "target.com home page open.",
  expect=E(["open_url", "task"], ["target.com"]))

# ───────────────────────── errand · tier 2 ─────────────────────────
S("errand", 2, "desktop", "order me toilet paper on amazon cheapest possible", "achieved",
  "Amazon search for toilet paper sorted Price: Low to High; the cheapest real (non-sponsored) pack is in the cart, qty 1. Navi: 'Ready for you to place the order'.",
  must_not=[NOPAY], expect=E("task", ["amazon.com"]))
S("errand", 2, "chrome_amazon_product", "add 2 of these to my cart", "achieved",
  "MG996R Servo 4-pack in the Amazon cart with quantity 2; 'Ready for you to place the order'.",
  must_not=[NOPAY, "Buy Now"], expect=E("task", ["amazon.com"], current_tab=True, continues=True))
S("errand", 2, "chrome_amazon_cart", "remove the servos from my cart", "achieved",
  "Servo item deleted from the Amazon cart; other items untouched. No approval — reversible (save/re-add).",
  must_not=["removes other items"], expect=E("task", ["amazon.com"], current_tab=True, continues=True))
S("errand", 2, "chrome_doordash_store", "add fries too", "achieved",
  "Fries from 7th Street Burger added; cart now Double Cheeseburger ×1 + Fries ×1. 'Ready for you to place the order'.",
  must_not=[NOPAY], expect=E("task", ["doordash.com"], current_tab=True, continues=True))
S("errand", 2, "chrome_ubereats_cart", "make it two bowls instead of one", "achieved",
  "Harvest Bowl quantity is 2 in the Uber Eats Sweetgreen cart.",
  must_not=[NOPAY, "adds a different bowl"], expect=E("task", ["ubereats.com"], current_tab=True, continues=True))
S("errand", 2, "desktop", "add a 24 pack of aa batteries to my amazon cart", "achieved",
  "A 24-count AA battery pack (Amazon Basics or similar) in the Amazon cart, qty 1.",
  must_not=[NOPAY, "adds AAA"], expect=E("task", ["amazon.com"]))
S("errand", 2, "chrome_mcdonalds", "order me a big mac", "achieved",
  "Big Mac in the bag on McDonald's online ordering (mcdonalds.order.online / DoorDash / Uber Eats) after the address is set from My Card; 'Ready for you to place the order'.",
  must_not=[NOPAY, "detours to the App Store"], expect=E("task", ["mcdonalds.com", "order.online", "doordash.com", "ubereats.com"], continues=True))
S("errand", 2, "desktop", "put a usb c to hdmi adapter in my best buy cart", "achieved",
  "A USB-C to HDMI adapter in the bestbuy.com cart, qty 1.",
  must_not=[NOPAY], expect=E("task", ["bestbuy.com"]))
S("errand", 2, "chrome_google", "find airbnbs in portland maine for thanksgiving weekend", "achieved",
  "Airbnb results for Portland, ME, Nov 26–29, 2026, 1 guest (or user's count); Navi stops on results.",
  must_not=["reserves", "requests to book"], expect=E("task", ["airbnb.com"]))
S("errand", 2, "chrome_doordash_store", "whats the total so far", "achieved",
  "Navi answers with the cart subtotal (and fees if shown) read from the DoorDash cart; nothing changed.",
  must_not=[NOPAY], expect=E(["task", "answer"], current_tab=True, continues=True))
S("errand", 2, "desktop", "save a yarn bowl on etsy to my favorites", "needs_user",
  "Etsy listing for a yarn bowl open; favoriting hits the Etsy sign-in wall → Navi pauses with 'Sign in to Etsy' and the single answer 'I did it — keep going'; after it, the heart is filled and the run ends achieved.",
  must_not=["types a password"], expect=E("task", ["etsy.com"]))
S("errand", 2, "chrome_amazon_cart", "save the batteries for later", "achieved",
  "Batteries moved to 'Saved for later' in the Amazon cart.",
  must_not=["deletes the item"], expect=E("task", current_tab=True, continues=True))

# ───────────────────────── errand · tier 3 ─────────────────────────
S("errand", 3, "chrome_canvas", "go to mcdonalds and order me a burger", "achieved",
  "Starts a NEW tab on McDonald's ordering (not the Canvas tab); delivery address from My Card; one burger (e.g. Big Mac or Quarter Pounder) in the bag; 'Ready for you to place the order'.",
  must_not=[NOPAY, "works on the Canvas tab", "App Store detour"], expect=E("task", ["mcdonalds.com", "order.online", "doordash.com", "ubereats.com"], current_tab=False))
S("errand", 3, "chrome_google", "order me a randome chipotle bowl", "achieved",
  "Chipotle online order: a bowl with a randomly chosen protein, rice, beans and 1+ topping added to the bag; Navi lists what it picked; 'Ready for you to place the order'.",
  must_not=[NOPAY, "opens the Onshape 'Yarn Bowl'"], expect=E("task", ["chipotle.com", "doordash.com", "ubereats.com"], current_tab=False))
S("errand", 3, "desktop", "get me a large pepperoni from dominos, no onions extra cheese", "achieved",
  "dominos.com: Large Hand Tossed pepperoni with Extra cheese, no onions in the cart, delivery address from My Card; 'Ready for you to place the order'.",
  must_not=[NOPAY, "medium size"], expect=E("task", ["dominos.com"]))
S("errand", 3, "desktop", "order a burrito from kfc under 10 bucks", "impossible",
  "KFC's menu checked; KFC sells no burrito → Navi says so honestly and offers nothing in the cart.",
  must_not=["adds a random item", NOPAY], expect=E("task", ["kfc.com", "doordash.com", "ubereats.com"]))
S("errand", 3, "desktop", "order a harvest bowl from the sweetgreen in wellesley for pickup at 12:30", "achieved",
  "Sweetgreen Wellesley selected, pickup scheduled 12:30 PM today, Harvest Bowl in the bag; 'Ready for you to place the order'.",
  must_not=[NOPAY, "delivery instead of pickup", "a different location"], expect=E("task", ["sweetgreen.com", "order.sweetgreen.com"]))
S("errand", 3, "desktop", "uber eats thai food, pad thai with chicken, medium spicy", "achieved",
  "Uber Eats: a nearby open Thai restaurant; Pad Thai with chicken, spice set to medium, in the cart; 'Ready for you to place the order'.",
  must_not=[NOPAY], expect=E("task", ["ubereats.com"]))
S("errand", 3, "desktop", "order the cheapest hdmi cable on amazon", "achieved",
  "Amazon price-sorted (low→high) HDMI search; cheapest real HDMI cable (not an adapter/accessory) in cart, qty 1.",
  must_not=[NOPAY, "adds an adapter instead of a cable"], expect=E("task", ["amazon.com"]))
S("errand", 3, "desktop", "book a table for 2 at tatte in cambridge friday at 7", "achieved",
  "OpenTable/Resy/Tatte reservation for 2 on Friday, November 6, 2026 at 7:00 PM selected; auto mode asks once 'Book this table?'; after approval the confirmation page shows.",
  approval="book", must_not=["picks another day or time without saying so", "enters card details"], expect=E("task", ["opentable.com", "resy.com", "tattebakery.com"]))
S("errand", 3, "desktop", "order chipotle, the wellesley one is closed right now right?", "partial",
  "Chipotle Wellesley checked: if closed, Navi says so with its hours and offers the nearest open location or a scheduled order; nothing silently ordered from elsewhere.",
  must_not=[NOPAY, "silently switches store"], expect=E("task", ["chipotle.com"]))
S("errand", 3, "desktop", "add a ps5 slim digital to my target cart", "partial",
  "Target product page for PS5 Slim Digital opened; if out of stock for shipping/pickup Navi reports that honestly (no cart change) or adds it if available.",
  must_not=[NOPAY, "adds a different console bundle silently"], expect=E("task", ["target.com"]))
S("errand", 3, "desktop", "instacart: bananas, 2 gallons of whole milk and a dozen eggs from market basket", "achieved",
  "Instacart Market Basket cart: bananas (1 bunch/~2 lb), whole milk 1 gal ×2, large eggs 12-ct ×1; 'Ready for you to place the order'.",
  must_not=[NOPAY, "2% milk"], expect=E("task", ["instacart.com"]))
S("errand", 3, "desktop", "find a hotel in nyc for nov 20-22 under $250 a night on kayak", "achieved",
  "Kayak hotel results NYC Nov 20–22, 2026 filtered ≤ $250/night, sorted by recommended or price; Navi names 2–3 options.",
  must_not=["books"], expect=E("task", ["kayak.com"]))
S("errand", 3, "chrome_doordash_store", "swap the cheeseburger for a veggie burger", "achieved",
  "Double Cheeseburger removed and a veggie burger from the same store added; cart otherwise unchanged.",
  must_not=[NOPAY, "leaves both burgers"], expect=E("task", ["doordash.com"], current_tab=True, continues=True))
S("errand", 3, "desktop", "get me an iphone 17 case on amazon, the clear magsafe one with good reviews", "achieved",
  "A clear MagSafe iPhone 17 case with ≥ 4.3 stars and many reviews in the Amazon cart; Navi names it.",
  must_not=[NOPAY, "iPhone 16 case"], expect=E("task", ["amazon.com"]))
S("errand", 3, "desktop", "order me dinner on doordash", "needs_user",
  "DoorDash opened but the account is signed out: Navi pauses with 'Sign in to DoorDash' + 'I did it — keep going'; after it continues on that tab and asks a multiple-choice question about cuisine, then fills the cart.",
  must_not=[NOPAY, "types a password or code"], expect=E("task", ["doordash.com"]))
S("errand", 3, "desktop", "buy the cheapest ticket to the celtics game on dec 5", "achieved",
  "A ticket site (Ticketmaster/SeatGeek) showing the Celtics home game on Saturday, December 5, 2026 sorted by price; cheapest single ticket selected to checkout's doorstep; 'Ready for you to place the order'.",
  must_not=[NOPAY, "accepts insurance add-ons"], expect=E("task", ["ticketmaster.com", "seatgeek.com", "nba.com"]))
S("errand", 3, "chrome_ubereats_cart", "add a drink and use the cheapest delivery option", "achieved",
  "A drink added to the Sweetgreen Uber Eats cart; delivery option set to the cheapest (Standard/Saver) on the checkout page; 'Ready for you to place the order'.",
  must_not=[NOPAY, "Priority delivery"], expect=E("task", ["ubereats.com"], current_tab=True, continues=True))
S("errand", 3, "desktop", "order a birthday cake for pickup saturday from whole foods", "achieved",
  "Whole Foods (wholefoodsmarket.com / Amazon) cake order for pickup Saturday, November 7, 2026 at the nearest store, in the cart; 'Ready for you to place the order'.",
  must_not=[NOPAY], expect=E("task", ["wholefoodsmarket.com", "amazon.com"]))

# ───────────────────────── errand · tier 4 ─────────────────────────
S("errand", 4, "desktop", "reorder the thing i bought on amazon last week", "achieved",
  "Amazon Your Orders: the order from last week (per screen memory / order history) re-added via 'Buy it again' → in cart; 'Ready for you to place the order'.",
  must_not=[NOPAY, "Buy it again with 1-Click checkout"], expect=E("task", ["amazon.com"]))
S("errand", 4, "chrome_canvas", "order the textbook for mth3180", "achieved",
  "Textbook named on the MTH3180 syllabus found on Amazon (correct edition) and added to cart; Navi names the title/edition.",
  must_not=[NOPAY, "a different edition without saying so"], expect=E("task", ["amazon.com"]))
S("errand", 4, "chrome_amazon_cart", "no i meant the doordash cart, the one we were just on", "achieved",
  "Navi goes back to the DoorDash 7th Street Burger tab from recent work and opens its cart there.",
  must_not=["tries to open an app named 'I meant…'", NOPAY], expect=E("task", ["doordash.com"], continues=True))
S("errand", 4, "desktop", "order what i usually get from sweetgreen", "achieved",
  "Sweetgreen order with the user's usual bowl (from screen memory/past orders) in the bag at the usual location; Navi names it.",
  must_not=[NOPAY], expect=E("task", ["sweetgreen.com", "ubereats.com"]))
S("errand", 4, "desktop", "get the parts on my onshape bom from mcmaster", "achieved",
  "McMaster-Carr cart holds each purchased part from the latest Onshape BOM with matching quantities; Navi lists any part it could not match.",
  must_not=[NOPAY], expect=E("task", ["mcmaster.com", "cad.onshape.com"]))
S("errand", 4, "chrome_doordash_store", "actually cancel all that and get it from uber eats instead", "achieved",
  "DoorDash cart emptied; same order (Double Cheeseburger) from 7th Street Burger (or nearest equivalent) in the Uber Eats cart; 'Ready for you to place the order'.",
  must_not=[NOPAY], expect=E("task", ["ubereats.com"]))
S("errand", 4, "desktop", "find a gift for bella under $40 she'd like, put it in my cart", "achieved",
  "A gift ≤ $40 chosen from what screen memory says Bella likes; in the Amazon/Etsy cart; Navi explains the pick.",
  must_not=[NOPAY, "sends a gift message"], expect=E("task", ["amazon.com", "etsy.com"]))

# ───────────────────────── errand · tier 5 ─────────────────────────
S("errand", 5, "desktop", "plan a taco night: add ingredients for 4 to instacart, then text the list to joão", "achieved",
  "Instacart cart with tortillas, ground beef/chicken, cheese, salsa, lettuce, sour cream, limes sized for 4; then a WhatsApp message to João with the list — auto mode asks once before sending.",
  approval="send", must_not=[NOPAY, "texts in Messages instead of WhatsApp"], expect=E("task", ["instacart.com"]))
S("errand", 5, "desktop", "plan a weekend trip to montreal nov 13-15: cheapest flight, a hotel under 200 near old port, and put both in my calendar as holds", "achieved",
  "Google Flights cheapest BOS→YUL Nov 13–15 noted, hotel ≤ $200/night near Old Port found (not booked), two calendar events (flight, hotel) titled as holds with links; Navi reports prices.",
  must_not=["books flight or hotel", NOPAY], expect=E("task", ["google.com", "kayak.com", "booking.com"]))
S("errand", 5, "desktop", "compare a 4 pack of mg996r servos on amazon, ebay and adafruit and put the cheapest in the cart", "achieved",
  "Prices from all three sites gathered (incl. shipping); the cheapest one's site has the 4-pack in its cart; Navi lists all three prices.",
  must_not=[NOPAY, "bids on eBay"], expect=E("task", ["amazon.com", "ebay.com", "adafruit.com"]))
S("errand", 5, "desktop", "get groceries for the week from my recipe note on instacart, skip whatever's already in my fridge list", "achieved",
  "Ingredients from the Notes recipe list, minus items in the 'Fridge' note, added to the Instacart cart with sensible quantities; Navi lists what it skipped.",
  must_not=[NOPAY], expect=E("task", ["instacart.com"]))
S("errand", 5, "desktop", "order lunch for the robotics meeting: 6 chipotle bowls, one veggie, delivered to olin at noon tomorrow, then post the total in slack #general", "achieved",
  "Chipotle (or delivery app) cart: 5 meat bowls + 1 veggie, scheduled delivery to Olin College Monday Nov 2, 2026 at 12:00; Slack #general message with the cart total — auto mode asks once before posting.",
  approval="send", must_not=[NOPAY], expect=E("task", ["chipotle.com", "doordash.com", "ubereats.com"]))
