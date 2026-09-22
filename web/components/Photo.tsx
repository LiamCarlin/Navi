import Image from "next/image";
import desk from "@/public/img/desk-dark.jpg";

/** One photographic moment: a MacBook on a dark desk, 12 columns wide, with a single line over it. */
export function Photo() {
  return (
    <section className="px-6 py-12 md:py-16" aria-label="A MacBook on a dark desk">
      <div className="relative mx-auto max-w-7xl overflow-hidden rounded-[16px] border border-line">
        <Image
          src={desk}
          alt="A MacBook Pro on a dark desk, lit from the screen"
          sizes="(max-width: 1280px) 100vw, 1280px"
          placeholder="blur"
          className="aspect-[3/2] w-full object-cover sm:aspect-[2/1]"
        />
        <div className="absolute inset-x-0 bottom-0 flex flex-col gap-1 bg-gradient-to-t from-black/70 to-transparent p-6 text-white sm:flex-row sm:items-end sm:justify-between sm:p-8">
          <p className="max-w-md text-balance text-[17px] font-medium leading-snug sm:text-[22px]">Your Mac, with someone at the keyboard when you aren’t.</p>
          <p className="text-[13px] text-white/60">Photo: Alex Bachor, Unsplash</p>
        </div>
      </div>
    </section>
  );
}
