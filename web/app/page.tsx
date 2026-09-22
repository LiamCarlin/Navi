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

export default function Home() {
  return (
    <div className="relative overflow-x-clip">
      <Nav />
      <main>
        <Hero />
        <Does />
        <Decides />
        <Talk />
        <Background />
        <Recall />
        <Pricing />
        <FAQ />
        <Waitlist />
      </main>
      <Footer />
    </div>
  );
}
