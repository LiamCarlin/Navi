import { Nav } from "@/components/Nav";
import { Hero } from "@/components/Hero";
import { AppStrip, Habits } from "@/components/Apps";
import { TypeTalk } from "@/components/TypeTalk";
import { Kinds } from "@/components/Kinds";
import { Anatomy } from "@/components/Anatomy";
import { Stats } from "@/components/Stats";
import { Voice } from "@/components/Voice";
import { Background } from "@/components/Background";
import { Recall } from "@/components/Recall";
import { Privacy } from "@/components/Privacy";
import { Pricing } from "@/components/Pricing";
import { FAQ } from "@/components/FAQ";
import { Waitlist } from "@/components/Waitlist";
import { Footer } from "@/components/Footer";
import { SeenOn } from "@/components/SeenOn";

export default function Home() {
  return (
    <div className="relative overflow-x-clip">
      <Nav />
      <main>
        <Hero />
        <AppStrip />
        <SeenOn />
        <TypeTalk />
        <Kinds />
        <Stats />
        <Anatomy />
        <Voice />
        <Background />
        <Habits />
        <Recall />
        <Privacy />
        <Pricing />
        <FAQ />
        <Waitlist />
      </main>
      <Footer />
    </div>
  );
}
