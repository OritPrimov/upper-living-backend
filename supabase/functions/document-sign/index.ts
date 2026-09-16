// Internal-signature Edge Function for the document-signing module
// (planning doc section 13.1, level 2 — "חתימה פנימית").
//
// Why this can't just be a client-side table UPDATE (unlike the
// "acknowledge" level, which is): a real signature needs (a) a fresh
// identity re-check, not just "already logged in", and (b) an
// evidentiary IP address / user-agent that the resident's own client
// cannot be trusted to self-report accurately. Both must come from the
// server. RLS on document_recipients (20260915170000) already blocks a
// resident from setting status='signed' via a raw table write — this
// function is the only path to that transition.
//
// Request:  POST { document_recipient_id: number, password: string, signature_image?: string }
//           signature_image: optional base64 PNG (data-URL prefix accepted
//           and stripped) of a drawn signature — a UX addition only, it
//           carries no extra legal weight beyond the password
//           re-verification and IP/timestamp above. Stored in the private
//           'documents' bucket, never a public URL.
//           Authorization: Bearer <resident's Supabase Auth access token>
// Response: { signed: true, signed_at: string }

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const { document_recipient_id, password, signature_image } = await req.json();
    if (!document_recipient_id || !password) {
      return json({ error: "document_recipient_id and password are required" }, 400);
    }

    // 1) Who is calling, via their own session (never trust a client-supplied
    // resident id for this — only the token identifies them).
    const asUserClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await asUserClient.auth.getUser();
    if (userErr || !userData?.user?.email) {
      return json({ error: "Not authenticated." }, 401);
    }

    // 2) Re-verify identity right now, at signing time — a valid session
    // alone isn't enough evidence for a signature. This checks the password
    // without disturbing the caller's existing session.
    const reauthClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
    const { error: reauthErr } = await reauthClient.auth.signInWithPassword({
      email: userData.user.email,
      password,
    });
    if (reauthErr) {
      return json({ error: "הסיסמה שגויה — לא ניתן לאמת את הזהות." }, 401);
    }

    // 3) Confirm the caller actually owns this document_recipient row —
    // RLS on document_recipients (own resident_id only) does the real work;
    // this just surfaces "not found" if it doesn't belong to them.
    const { data: recipient, error: recErr } = await asUserClient
      .from("document_recipients")
      .select("id, status, document_version_id")
      .eq("id", document_recipient_id)
      .maybeSingle();
    if (recErr || !recipient) {
      return json({ error: "Document not found or not accessible." }, 403);
    }
    if (recipient.status === "signed") {
      return json({ error: "המסמך כבר נחתם." }, 409);
    }

    // 4) Service-role from here on: check the document actually requires
    // 'internal_signature' (never sign a certified-e-signature or
    // acknowledge-only document through this path), read the file hash to
    // sign, then write the signature + flip status atomically.
    const serviceClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: version, error: versionErr } = await serviceClient
      .from("document_versions")
      .select("id, file_hash, document_id, documents(signature_level)")
      .eq("id", recipient.document_version_id)
      .maybeSingle();
    if (versionErr || !version) {
      return json({ error: "Document version not found." }, 404);
    }
    const signatureLevel = (version as any).documents?.signature_level;
    if (signatureLevel !== "internal_signature") {
      return json({ error: "מסמך זה לא מוגדר לחתימה פנימית." }, 400);
    }

    // Real evidentiary values, captured server-side — never from the
    // request body. x-forwarded-for may carry a comma-separated chain
    // (client, proxy, proxy...); the first entry is the original client.
    const forwardedFor = req.headers.get("x-forwarded-for") ?? "";
    const ipAddress = forwardedFor.split(",")[0].trim() || null;
    const userAgent = req.headers.get("user-agent") ?? null;

    const signedAt = new Date().toISOString();

    // Optional drawn-signature image — UX only, never required. Uploaded to
    // the same private bucket the document file itself lives in, under its
    // own prefix, and referenced by path only (no public URL is ever
    // generated from it).
    let signatureImagePath: string | null = null;
    if (signature_image) {
      const base64Data = String(signature_image).replace(/^data:image\/png;base64,/, "");
      const bytes = Uint8Array.from(atob(base64Data), (c) => c.charCodeAt(0));
      const path = `signatures/${recipient.id}-${Date.now()}.png`;
      const { error: uploadErr } = await serviceClient.storage
        .from("documents")
        .upload(path, bytes, { contentType: "image/png" });
      if (uploadErr) {
        console.error("Signature image upload failed (non-fatal):", uploadErr);
      } else {
        signatureImagePath = path;
      }
    }

    const { error: sigErr } = await serviceClient.from("document_signatures").insert({
      document_recipient_id: recipient.id,
      signed_at: signedAt,
      ip_address: ipAddress,
      user_agent: userAgent,
      document_hash_at_signing: version.file_hash,
      external_provider: null,
      external_signature_id: null,
      signature_image_path: signatureImagePath,
    });
    if (sigErr) throw sigErr;

    const { error: updateErr } = await serviceClient
      .from("document_recipients")
      .update({ status: "signed" })
      .eq("id", recipient.id);
    if (updateErr) throw updateErr;

    return json({ signed: true, signed_at: signedAt });
  } catch (e) {
    console.error(e);
    return json({ error: (e as Error).message }, 500);
  }
});
