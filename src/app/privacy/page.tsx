import type { Metadata } from "next";
import Link from "next/link";
import { Logo } from "@/components/ui/logo";

export const metadata: Metadata = {
  title: "OpenKanban - Privacy Policy",
  description:
    "How OpenKanban handles account identity and private board data.",
};

export default function PrivacyPage() {
  return (
    <div className="min-h-screen bg-black pb-32 font-sans text-white selection:bg-accent selection:text-black">
      {/* Header */}
      <header className="border-neutral-900 border-b px-6 py-6">
        <div className="mx-auto flex max-w-4xl items-center justify-between">
          <Logo size={24} className="transition-opacity hover:opacity-80" />
          <Link
            href="/"
            className="text-neutral-400 text-sm transition-colors hover:text-white"
          >
            Back to Home
          </Link>
        </div>
      </header>

      {/* Content */}
      <main className="mx-auto max-w-3xl px-6 pt-24">
        <h1 className="mb-6 font-bold font-display text-5xl tracking-tight md:text-6xl">
          Privacy Policy.
        </h1>
        <p className="mb-16 font-mono text-accent text-sm">
          Last updated: {new Date().toLocaleDateString()}
        </p>

        <div className="space-y-12 text-neutral-300 leading-relaxed">
          <section>
            <h2 className="mb-4 font-bold font-display text-2xl text-white">
              1. Data Collection Philosophy
            </h2>
            <p className="mb-4">
              OpenKanban requires a Google account that has been explicitly
              enabled for the application. Authentication is provided by
              Supabase and Google.
            </p>
            <p className="mb-4 font-bold text-white">
              OpenKanban stores the account identifier and verified Google email
              needed to admit and identify your account. It does not receive
              your Google password.
            </p>
          </section>

          <section>
            <h2 className="mb-4 font-bold font-display text-2xl text-white">
              2. What We Collect
            </h2>
            <ul className="mt-2 list-disc space-y-2 pl-5">
              <li>
                <strong>Board Data:</strong> The text content, structures, and
                states of the Kanban boards you create are stored in our
                database strictly to synchronize them between your active
                sessions.
              </li>
              <li>
                <strong>Authentication data:</strong> Google and Supabase
                process authentication information needed to sign in and
                maintain your session.
              </li>
            </ul>
          </section>

          <section>
            <h2 className="mb-4 font-bold font-display text-2xl text-white">
              3. Data Visibility & Security
            </h2>
            <p className="mb-4">
              OpenKanban checks your authenticated account and its explicit
              application access before serving a board. Each board belongs to
              its owner account. An administrator can manage who may use the
              application, but that role does not grant access to another
              account's board content.
            </p>
            <p className="mb-4 text-neutral-400 italic">
              Board URLs identify a route and do not grant access by themselves.
            </p>
          </section>

          <section>
            <h2 className="mb-4 font-bold font-display text-2xl text-white">
              4. Third-Party Services
            </h2>
            <p className="mb-4">
              Google, Supabase, and the hosting provider process data needed to
              authenticate, store, and deliver the service. Board content is not
              shared with other application accounts unless a future
              collaboration feature explicitly grants access.
            </p>
          </section>

          <section>
            <h2 className="mb-4 font-bold font-display text-2xl text-white">
              5. Deletion & Retention
            </h2>
            <p className="mb-4">
              You can manually delete data from your board at any time, which
              deletes it from our active synchronization state. We do not
              explicitly design the system for permanent archival purposes.
            </p>
          </section>
        </div>
      </main>
    </div>
  );
}
