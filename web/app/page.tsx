import { Nav } from "@/components/Nav";
import { Hero } from "@/components/Hero";
import { Features } from "@/components/Features";
import { Recall } from "@/components/Recall";
import { Voice } from "@/components/Voice";
import { Pricing } from "@/components/Pricing";
import { FAQ } from "@/components/FAQ";
import { Waitlist } from "@/components/Waitlist";
import { Footer } from "@/components/Footer";

export default function Home() {
  return (
    <div className="relative overflow-x-clip">
      <div className="page-glow" aria-hidden="true" />
      <Nav />
      <main>
        <Hero />
        <Features />
        <Recall />
        <Voice />
        <Pricing />
        <FAQ />
        <Waitlist />
      </main>
      <Footer />
    </div>
  );
}
