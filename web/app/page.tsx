import { Nav } from "@/components/Nav";
import { Hero } from "@/components/Hero";
import { Film } from "@/components/Film";
import { Kinds } from "@/components/Kinds";
import { Anatomy } from "@/components/Anatomy";
import { Voice } from "@/components/Voice";
import { Background } from "@/components/Background";
import { Apps } from "@/components/Apps";
import { Recall } from "@/components/Recall";
import { Privacy } from "@/components/Privacy";
import { Pricing } from "@/components/Pricing";
import { FAQ } from "@/components/FAQ";
import { Waitlist } from "@/components/Waitlist";
import { Footer } from "@/components/Footer";
import { StickyCTA } from "@/components/StickyCTA";
import { SeenOn } from "@/components/SeenOn";

export default function Home() {
  return (
    <div className="relative overflow-x-clip">
      <Nav />
      <main>
        <Hero />
        <SeenOn />
        <Film />
        <Kinds />
        <Anatomy />
        <Voice />
        <Background />
        <Apps />
        <Recall />
        <Privacy />
        <Pricing />
        <FAQ />
        <Waitlist />
      </main>
      <Footer />
      <StickyCTA />
    </div>
  );
}
