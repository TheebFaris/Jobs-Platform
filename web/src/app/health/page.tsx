// TEMPORARY page to verify the database connection. DELETE this folder before going live.
import { Suspense } from "react";
import { createAdminClient } from "@/lib/supabase/admin";

async function Checks() {
  const expected = { sectors: 19, job_titles: 186 };
  try {
    const db = createAdminClient();
    const [s, t] = await Promise.all([
      db.from("sectors").select("*", { count: "exact", head: true }),
      db.from("job_titles").select("*", { count: "exact", head: true }),
    ]);
    if (s.error || t.error) {
      throw new Error((s.error ?? t.error)!.message);
    }
    const okS = s.count === expected.sectors;
    const okT = t.count === expected.job_titles;
    return (
      <ul style={{ lineHeight: 2 }}>
        <li>
          {okS ? "✅" : "⚠️"} عدد القطاعات: {s.count} (المتوقع {expected.sectors})
        </li>
        <li>
          {okT ? "✅" : "⚠️"} عدد المسميات الوظيفية: {t.count} (المتوقع {expected.job_titles})
        </li>
        <li>{okS && okT ? "✅ الاتصال سليم" : "⚠️ الاتصال يعمل لكن الأرقام غير مطابقة"}</li>
      </ul>
    );
  } catch (e) {
    return (
      <p style={{ color: "crimson" }}>
        ❌ فشل الاتصال: {e instanceof Error ? e.message : "خطأ غير معروف"}
      </p>
    );
  }
}

export default function HealthPage() {
  return (
    <main dir="rtl" style={{ maxWidth: 640, margin: "4rem auto", padding: "0 1rem", fontFamily: "system-ui, Arial, sans-serif" }}>
      <h1 style={{ fontSize: "1.5rem", fontWeight: 700 }}>فحص الاتصال بقاعدة البيانات</h1>
      <Suspense fallback={<p>جاري الفحص...</p>}>
        <Checks />
      </Suspense>
    </main>
  );
}
