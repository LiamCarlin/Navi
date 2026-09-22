import { Nav } from "@/components/Nav";
import { Hero } from "@/components/Hero";
import { Does } from "@/components/Does";
import { Decides } from "@/components/Decides";
import { Talk } from "@/components/Talk";
import { Background } from "@/components/Background";
import { Recall } from "@/components/Recall";
import { Pricing } from "@/components/Pricing";
import { FAQ } from "@/components/FAQ";
import { Waitlist } from "@/components/Waitlist";
import { Footer } from "@/components/Footer";
import { MidCTA } from "@/components/MidCTA";
import { StickyCTA } from "@/components/StickyCTA";
import { SeenOn } from "@/components/SeenOn";
import { Photo } from "@/components/Photo";

export default function Home() {
  return (
    <div className="relative overflow-x-clip">
      <Nav />
      <main>
        <Hero />
        <SeenOn />
        <Does />
        <Decides />
        <MidCTA source="mid-02" />
        <Talk />
        <Photo />
        <Background />
        <MidCTA source="mid-04" />
        <Recall />
        <Pricing />
        <FAQ />
        <Waitlist />
        <SeenOn className="pb-8" />
      </main>
      <Footer />
      <StickyCTA />
    </div>
  );
}
