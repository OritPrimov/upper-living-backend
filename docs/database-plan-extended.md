# תוספות לתכנון בסיס הנתונים — מתוך שיחות תכנון נפרדות

מסמך זה אוסף סעיפי תכנון נוספים שהוכנו בשיחות Claude נפרדות (לא בפרויקט הזה), ומיובאים לכאן לצורך תיעוד לפני שהם הופכים ל-migration בפועל.

**הערה חשובה:** סעיפים 23–28 (למטה) נבדקו לעומק מול הסכמה הקיימת שלנו ותורגמו ל-migrations בפועל:
- סעיף 23 → [20260914120000_community_resources_booking.sql](../supabase/migrations/20260914120000_community_resources_booking.sql)
- סעיפים 24–28 → [20260914130000_vehicles_potluck_dinners.sql](../supabase/migrations/20260914130000_vehicles_potluck_dinners.sql) (תלוי בקובץ של סעיף 23 — חייב לרוץ אחריו)

---

## 23. ניהול משאבים קהילתיים (הזמנת מתקנים)

### 23.1 החלטות תכנון לפני הטבלאות

**א. "תופס לגמרי" מול "לפי תפוסה" — לא כל משאב מתנהג אותו דבר.**
אולם אירועים הוא בלעדי: הזמנה אחת סוגרת את כל חלון הזמן לכולם. חדר כושר הוא לפי תפוסה: כמה דיירים יכולים "להירשם" לאותה שעה, עד תקרה מסוימת. זה לא הבדל קוסמטי — זו לוגיקת מניעת-כפילויות שונה לגמרי, וצריך לתכנן את שתיהן מראש ולא רק את המקרה הפשוט.

**ב. מחיר הוא תכונה של המשאב, לא של ההזמנה — אבל ניתן לדריסה נקודתית.**
`community_resources.is_paid`/`price_amount` הם ברירת המחדל, ו-`resource_bookings.charged_amount` הוא מה שבפועל נגבה באותה הזמנה ספציפית — כך אפשר גם לוותר על תשלום חד-פעמית (למשל אירוע ועד בית באולם) בלי לשנות את מחיר המשאב הקבוע.

**ג. תהליך אישור הוא תכונה של המשאב, לא כלל גורף.** חלק מהמשאבים (חניית אורחים) לא צריכים אישור אנושי; אחרים (אולם אירועים, בגלל התנגשויות ותשלום) כן. זה מקודד ב-`requires_approval` על המשאב, ומשתלב באותו דפוס סטטוס (`pending_approval`/`confirmed`) שכבר משמש בשאר המערכת.

**ד. חסימות תחזוקה נפרדות מהזמנות בפועל.** "המשאב לא זמין ביום שלישי בבוקר לניקיון" היא עובדה על המשאב, לא הזמנה של אף אחד — טבלה נפרדת, לא "הזמנת דמה" שתבלבל דוחות שימוש.

### 23.2 טבלת המשאבים

```sql
CREATE TABLE community_resources (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  community_id UUID NOT NULL REFERENCES communities(id),
  building_id UUID REFERENCES buildings(id),        -- NULL = משותף לכל הקהילה
  name TEXT NOT NULL,                                 -- "אולם אירועים", "חדר כושר"
  category TEXT NOT NULL,                             -- 'event_hall' / 'bbq' / 'parking' / 'gym' / 'meeting_room'
  description TEXT,
  location_notes TEXT,                                -- "קומת קרקע, ליד הלובי"
  photo_url TEXT,
  usage_rules TEXT,                                   -- תקנון שימוש מוצג לדייר לפני הזמנה
  capacity INT,                                        -- לאנשים (concurrent) או קיבולת (exclusive)
  booking_mode TEXT NOT NULL DEFAULT 'exclusive'
    CHECK (booking_mode IN ('exclusive','concurrent')),
  is_paid BOOLEAN NOT NULL DEFAULT false,
  price_amount NUMERIC(10,2),
  price_unit TEXT CHECK (price_unit IN ('per_hour','per_booking','per_day')),
  deposit_amount NUMERIC(10,2),
  requires_approval BOOLEAN NOT NULL DEFAULT false,
  min_booking_minutes INT NOT NULL DEFAULT 30,
  max_booking_minutes INT,
  buffer_minutes INT NOT NULL DEFAULT 0,              -- זמן ניקיון/מעבר בין הזמנות
  advance_booking_days INT NOT NULL DEFAULT 60,       -- כמה קדימה מותר להזמין
  min_advance_notice_hours INT NOT NULL DEFAULT 0,    -- לא ניתן להזמין ברגע האחרון
  max_bookings_per_resident_per_month INT,            -- הגבלת הוגנות שימוש
  available_hours JSONB,                               -- שעות פתיחה לפי יום בשבוע
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active','maintenance','inactive')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### 23.3 טבלת ההזמנות/הקצאות

```sql
CREATE TABLE resource_bookings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  resource_id UUID NOT NULL REFERENCES community_resources(id),
  resident_id UUID NOT NULL REFERENCES residents(id),   -- עבור מי ההזמנה
  created_by_staff_id UUID REFERENCES staff_users(id),  -- NULL אם הדייר הזמין בעצמו
  start_time TIMESTAMPTZ NOT NULL,
  end_time TIMESTAMPTZ NOT NULL,
  attendee_count INT,                                    -- רלוונטי בעיקר למשאבי concurrent
  status TEXT NOT NULL DEFAULT 'confirmed'
    CHECK (status IN ('pending_approval','confirmed','rejected','cancelled','completed','no_show')),
  is_charged BOOLEAN NOT NULL DEFAULT false,
  charged_amount NUMERIC(10,2),
  payment_status TEXT NOT NULL DEFAULT 'unpaid'
    CHECK (payment_status IN ('unpaid','paid','waived','refunded')),
  notes TEXT,
  cancelled_by_type TEXT CHECK (cancelled_by_type IN ('resident','staff')),
  cancelled_by_id UUID,
  cancellation_reason TEXT,
  cancelled_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (end_time > start_time)
);
```

**מניעת כפילויות — בטריגר, לא בעיוורון:** מנגנון סטנדרטי של "אילוץ ייחודיות" ב-Postgres לא מספיק כאן, כי לחלק מהמשאבים מותר חפיפה (עד תפוסה) ולחלק אסור לגמרי. הפתרון: טריגר שבודק את `booking_mode` של המשאב הרלוונטי לפני כל הזמנה:

```sql
CREATE OR REPLACE FUNCTION check_resource_booking_capacity() RETURNS TRIGGER AS $$
DECLARE
  v_mode TEXT;
  v_capacity INT;
  v_overlap_count INT;
BEGIN
  SELECT booking_mode, capacity INTO v_mode, v_capacity
  FROM community_resources WHERE id = NEW.resource_id;

  SELECT count(*) INTO v_overlap_count
  FROM resource_bookings
  WHERE resource_id = NEW.resource_id
    AND status IN ('pending_approval','confirmed')
    AND id <> COALESCE(NEW.id, gen_random_uuid())
    AND tstzrange(start_time, end_time) && tstzrange(NEW.start_time, NEW.end_time);

  IF v_mode = 'exclusive' AND v_overlap_count > 0 THEN
    RAISE EXCEPTION 'המשאב כבר תפוס בטווח הזמן הזה';
  ELSIF v_mode = 'concurrent' AND v_overlap_count >= COALESCE(v_capacity, 1) THEN
    RAISE EXCEPTION 'המשאב הגיע לתפוסה המקסימלית בטווח הזמן הזה';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_resource_booking_capacity
BEFORE INSERT OR UPDATE ON resource_bookings
FOR EACH ROW EXECUTE FUNCTION check_resource_booking_capacity();
```

זה מבטיח ברמת בסיס הנתונים עצמו (לא רק ב-UI) שאף אחד לא יכול "לגנוב" הזמנה כפולה על אולם, בין אם הבקשה הגיעה מהאפליקציה, מ-Retool, או משאילתה ידנית של הצוות.

### 23.4 חסימות תחזוקה — נפרדות מהזמנות

```sql
CREATE TABLE resource_blackout_periods (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  resource_id UUID NOT NULL REFERENCES community_resources(id),
  start_time TIMESTAMPTZ NOT NULL,
  end_time TIMESTAMPTZ NOT NULL,
  reason TEXT,                       -- "ניקיון שבועי", "תחזוקת מזגן"
  created_by UUID REFERENCES staff_users(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### 23.5 RLS

`community_resources` יש לו `community_id` ישיר וקל להגן עליו. `resource_bookings` אין — הקשר עובר דרך `resource_id`, ולכן דורש מדיניות עקיפה:

```sql
ALTER TABLE community_resources ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON community_resources
  USING (community_id = current_setting('app.current_community_id', true)::uuid);

ALTER TABLE resource_bookings ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON resource_bookings
  USING (
    resource_id IN (
      SELECT id FROM community_resources
      WHERE community_id = current_setting('app.current_community_id', true)::uuid
    )
  );
```

### 23.6 שאילתות למסכי הניהול

**רשימת כל ההזמנות למשאב נתון (לרשימה וליומן כאחד — אותה שאילתה, שני תצוגות):**

```sql
SELECT rb.*, r.full_name AS resident_name, r.phone
FROM resource_bookings rb
JOIN residents r ON r.id = rb.resident_id
WHERE rb.resource_id = :resource_id
  AND rb.status NOT IN ('cancelled','rejected')
ORDER BY rb.start_time;
```

**יצירת הקצאה חדשה על ידי הצוות** — קובעים `is_charged`/`charged_amount` מברירת המחדל של המשאב, אלא אם הצוות דורס אותם ידנית:

```sql
INSERT INTO resource_bookings
  (resource_id, resident_id, created_by_staff_id, start_time, end_time, is_charged, charged_amount, status)
SELECT
  :resource_id, :resident_id, :staff_id, :start_time, :end_time,
  cr.is_paid,
  CASE WHEN :waive_fee THEN NULL ELSE cr.price_amount END,
  CASE WHEN cr.requires_approval THEN 'pending_approval' ELSE 'confirmed' END
FROM community_resources cr WHERE cr.id = :resource_id;
```

ברירת המחדל מגיעה מהמשאב, אבל דגל `:waive_fee` מאפשר לצוות לוותר על החיוב בהקצאה ספציפית בלי לגעת בתמחור הקבוע.

### 23.7 חיבור לאנליטיקה

מוסיפים ל-`activity_events.event_type` את הערכים `resource_booked` / `resource_cancelled` / `resource_no_show` — כך שאלות עתידיות כמו "איזה משאב הכי מבוקש", "שיעור ביטולים לפי משאב", או "האם צריך משאב שני מאותו סוג" מתקבלות מאותה תשתית שכבר קיימת, בלי טבלת אנליטיקה ייעודית.

---

## 24. רכבים שיתופיים — הרחבת מערכת המשאבים

### 24.1 למה זה לא סתם עוד שורה ב-`community_resources`

רכב הוא `community_resources` עם `category='shared_vehicle'` — משתמש באותה טבלת הזמנות (`resource_bookings`), אותו טריגר מניעת כפילויות, ואותה RLS. אבל לרכב יש שני צרכים אמיתיים שמשאב רגיל (אולם, חדר כושר) לא צריך:

1. **מצב חי, לא רק לוח עתידי** — "פנוי עכשיו" תלוי בסוללה/דלק ובמיקום בפועל, לא רק בשאלה אם יש הזמנה בלוח.
2. **תיעוד לפני/אחרי שימוש** — מי לקח את הרכב באיזה מצב, ומי החזיר אותו באיזה מצב (ק"מ, רמת סוללה, נזק) — לצורך אחריות בין דיירים, לא רק תזמון.

לכן צריך שתי טבלאות הרחבה, לא שינוי בטבלת הליבה.

### 24.2 פרטי הרכב — טבלת הרחבה 1:1

```sql
CREATE TABLE vehicle_details (
  resource_id UUID PRIMARY KEY REFERENCES community_resources(id),
  license_plate TEXT NOT NULL,
  make_model TEXT,
  fuel_type TEXT NOT NULL DEFAULT 'electric'
    CHECK (fuel_type IN ('electric','gasoline','diesel','hybrid')),
  current_charge_percent INT CHECK (current_charge_percent BETWEEN 0 AND 100),
  current_fuel_percent INT CHECK (current_fuel_percent BETWEEN 0 AND 100),
  current_odometer_km INT,
  parking_spot TEXT,
  live_status TEXT NOT NULL DEFAULT 'available'
    CHECK (live_status IN ('available','in_use','maintenance','out_of_service')),
  last_service_at DATE,
  next_service_due_km INT,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

`live_status` נפרד בכוונה מ-`resource_bookings.status` — הזמנה יכולה להיות מאושרת בלוח, אבל הרכב עדיין "פנוי" עד שהוא בפועל נלקח, ו"בשימוש" עד שהוא בפועל מוחזר. זה מצב תפעולי חי, לא לוח זמנים.

### 24.3 יומן נסיעות — תיעוד לפני/אחרי, קשור להזמנה קונקרטית

```sql
CREATE TABLE vehicle_trip_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  booking_id UUID NOT NULL REFERENCES resource_bookings(id),
  checkout_at TIMESTAMPTZ,
  checkout_odometer_km INT,
  checkout_charge_percent INT,
  checkout_photo_url TEXT,
  checkin_at TIMESTAMPTZ,
  checkin_odometer_km INT,
  checkin_charge_percent INT,
  checkin_photo_url TEXT,
  damage_reported BOOLEAN NOT NULL DEFAULT false,
  damage_notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

תמונה לפני ותמונה אחרי (`checkout_photo_url`/`checkin_photo_url`) הן ההגנה המעשית בסכסוך "מי גרם לשריטה" — שומרים ראיה חזותית להוכיח מצב הרכב בכל מסירה.

### 24.4 סנכרון אוטומטי בין יומן הנסיעה למצב הרכב החי

```sql
CREATE OR REPLACE FUNCTION sync_vehicle_status() RETURNS TRIGGER AS $$
DECLARE
  v_resource_id UUID;
BEGIN
  SELECT resource_id INTO v_resource_id FROM resource_bookings WHERE id = NEW.booking_id;

  IF NEW.checkin_at IS NOT NULL THEN
    UPDATE vehicle_details SET
      live_status = 'available',
      current_odometer_km = NEW.checkin_odometer_km,
      current_charge_percent = NEW.checkin_charge_percent,
      updated_at = now()
    WHERE resource_id = v_resource_id;
  ELSIF NEW.checkout_at IS NOT NULL THEN
    UPDATE vehicle_details SET
      live_status = 'in_use',
      current_odometer_km = NEW.checkout_odometer_km,
      current_charge_percent = NEW.checkout_charge_percent,
      updated_at = now()
    WHERE resource_id = v_resource_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_vehicle_status
  AFTER INSERT OR UPDATE ON vehicle_trip_logs
  FOR EACH ROW EXECUTE FUNCTION sync_vehicle_status();
```

כך הדייר הבא שפותח את מסך "רכבים" רואה תמיד את המצב האמיתי (סוללה, ק"מ, זמינות) — מסירת הרכב היא מקור האמת היחיד.

### 24.5 RLS לטבלאות החדשות

```sql
ALTER TABLE vehicle_details ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON vehicle_details
  USING (
    resource_id IN (
      SELECT id FROM community_resources
      WHERE community_id = current_setting('app.current_community_id', true)::uuid
    )
  );

ALTER TABLE vehicle_trip_logs ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON vehicle_trip_logs
  USING (
    booking_id IN (
      SELECT rb.id FROM resource_bookings rb
      JOIN community_resources cr ON cr.id = rb.resource_id
      WHERE cr.community_id = current_setting('app.current_community_id', true)::uuid
    )
  );
```

---

## 25. תיקוף קילומטראז' והרחבת המוקאפים — צילום ועדכון בקבלה/החזרה

### 25.1 הגנה מפני קילומטראז' לא הגיוני

```sql
ALTER TABLE vehicle_trip_logs
  ADD CONSTRAINT checkin_odometer_after_checkout
  CHECK (checkin_odometer_km IS NULL OR checkout_odometer_km IS NULL
         OR checkin_odometer_km >= checkout_odometer_km);
```

### 25.2 מיפוי למוקאפים

תהליך המסירה/החזרה כולל: שדה קילומטראז', שדה אחוז סוללה, כפתור "צלם/י את מצב הרכב", ובהחזרה גם טוגל "לדווח על נזק" — ממופה 1:1 לעמודות `vehicle_trip_logs`.

### 25.3 מה עוד נדרש כדי שזה יהיה מוצר עובד, לא רק מוקאפ

**אלה החלטות מוצר/תשתית, לא migration — נשארות פתוחות עד שתחליטי:**

1. **אחסון תמונות בפועל** — נוצר bucket ייעודי `vehicle-trip-photos` ב-Supabase Storage (במסגרת ה-migration של סעיפים 24–28), פרטי (לא ציבורי). נשאר לחבר את כפתור "צלם" בפועל להעלאה אליו ולשמירת ה-URL החתום.
2. **חובה או רשות** — האם צילום חובה לפני "אשר החזרה"? מומלץ בטקסט המקורי: כן, לפחות בהחזרה.
3. **התראה אוטומטית כשמדווח נזק** — הרחבה טבעית ל-`activity_events`/`security_audit_log` הקיימים.
4. **גישת מצלמה במובייל** — `<input type="file" accept="image/*" capture="environment">` ב-build האמיתי.
5. **מדיניות ללא אינטרנט/מצלמה זמינה** — האם לאפשר מסירה זמנית בלי תמונה.

---

## 26. מודול חדש: ארוחה משותפת (פוטלאק)

### 26.1 החלטות תכנון

**א. פוטלאק הוא הרחבה של אירוע קיים, לא ישות חדשה.** ארוחה משותפת היא `events` רגיל שיש לו שורות ב-`potluck_items`. אם אין שורות — זה אירוע רגיל. אין דגל `is_potluck`; הקיום של הפריטים הוא הסימן.

**ב. טבלה אחת משרתת גם "בקשות מהמארגנת" וגם "הצעות חופשיות מדיירים".** סלוט פתוח בלי שם (`resident_id IS NULL`) ודייר שמוסיף בעצמו (`claimed`) הם אותה שורה בשתי נקודות שונות בציר החיים שלה.

**ג. מניעת "שני אנשים תפסו את אותה עוגה" — עדכון אטומי, לא טבלת נעילה:**

```sql
UPDATE potluck_items
SET resident_id = :resident_id, status = 'claimed', claimed_at = now()
WHERE id = :item_id AND status = 'open'
RETURNING id;
```

אם השאילתה מחזירה 0 שורות — מישהו כבר תפס, וה-UI מציג "מישהו כבר הביא את זה".

**ד. במכוון — בלי אישור צוות, בלי תשלום.** אין כסף מעורב, אין סיכון משפטי, ואין צורך במעורבות מנהלת קהילה.

### 26.2 הטבלה

```sql
CREATE TABLE potluck_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id UUID NOT NULL REFERENCES events(id),
  category TEXT NOT NULL
    CHECK (category IN ('starter','main','dessert','drink','disposables','other')),
  item_name TEXT,
  quantity_needed INT NOT NULL DEFAULT 1,
  resident_id UUID REFERENCES residents(id),
  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','claimed','cancelled')),
  claimed_at TIMESTAMPTZ,
  cancelled_at TIMESTAMPTZ,
  created_by UUID REFERENCES residents(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE event_rsvps ADD COLUMN notes TEXT;
```

### 26.3 שאילתת "איזון קטגוריות"

```sql
SELECT category,
  count(*) FILTER (WHERE status = 'claimed') AS claimed_count,
  coalesce(sum(quantity_needed) FILTER (WHERE status = 'open'), 0) AS still_needed
FROM potluck_items
WHERE event_id = :event_id
GROUP BY category;
```

מאפשר הודעה חכמה כמו "יש לנו מספיק קינוחים — עדיין חסרות 2 מנות עיקריות" בלי לוגיקה נוספת.

### 26.4 שימוש חוזר במנגנון תגובות קיים

```sql
ALTER TABLE reactions DROP CONSTRAINT reactions_target_type_check;
ALTER TABLE reactions ADD CONSTRAINT reactions_target_type_check
  CHECK (target_type IN ('post','comment','event','potluck_item'));
```

### 26.5 RLS

```sql
ALTER TABLE potluck_items ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON potluck_items
  USING (
    event_id IN (
      SELECT id FROM events
      WHERE community_id = current_setting('app.current_community_id', true)::uuid
    )
  );
```

### 26.6 חיבור לאנליטיקה ולעתיד

מוסיפים ל-`activity_events.event_type` את `potluck_item_claimed`. הרחבות עתידיות (לא נדרשות עכשיו): תזכורת אוטומטית לדיירים שנרשמו אך לא תפסו פריט; תמונה של המנה בפועל.

---

## 27. מודול חדש: ארוחות היכרות בבית דייר (4–8 משתתפים)

### 27.1 החלטות תכנון

**א. שוב הרחבה של `events`, עם שתי תוספות: מארחת ותקרת משתתפים.** טבלת הרחבה `dinner_gatherings` (1:1 עם `event_id`).

**ב. בלי אישור צוות.** דייר שיוצר ארוחת היכרות כבר עבר אימות זהות בהרשמה — אמון שכנות בסיסי, לא אמון מסחרי.

**ג. תקרת משתתפים מטופלת ברשימת המתנה אוטומטית, לא בדחייה.** כשהמקום ה-8 תפוס, הדייר ה-9 עובר לסטטוס `waitlisted` — זרימה תקינה, לא שגיאה.

**ד. שלושת סוגי הארוחה משתמשים באותו `potluck_items`.** "המארחת מכינה הכל" = בלי שורות. "לפי קונספט"/"חופשי" = אותו מנגנון מסעיף 26.

**ה. פרטיות: הכתובת נחשפת רק למי שבאמת מגיע** (`event_rsvps.status` = `going`/`waitlisted` בלבד) — החלטת שאילתה/אפליקציה, לא עמודה נוספת.

### 27.2 טבלת ההרחבה

```sql
CREATE TABLE dinner_gatherings (
  event_id UUID PRIMARY KEY REFERENCES events(id),
  host_resident_id UUID NOT NULL REFERENCES residents(id),
  min_participants INT NOT NULL DEFAULT 4,
  max_participants INT NOT NULL DEFAULT 8,
  meal_type TEXT NOT NULL DEFAULT 'host_provides'
    CHECK (meal_type IN ('host_provides','potluck_theme','potluck_free')),
  theme_description TEXT,
  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','full','cancelled','completed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### 27.3 תקרת משתתפים + רשימת המתנה אוטומטית

```sql
ALTER TABLE event_rsvps DROP CONSTRAINT event_rsvps_status_check;
ALTER TABLE event_rsvps ADD CONSTRAINT event_rsvps_status_check
  CHECK (status IN ('going','maybe','declined','waitlisted'));
```

```sql
CREATE OR REPLACE FUNCTION check_dinner_gathering_capacity() RETURNS TRIGGER AS $$
DECLARE
  v_max INT;
  v_going_count INT;
BEGIN
  SELECT max_participants INTO v_max FROM dinner_gatherings WHERE event_id = NEW.event_id;
  IF v_max IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'going' THEN
    SELECT count(*) INTO v_going_count
    FROM event_rsvps
    WHERE event_id = NEW.event_id AND status = 'going' AND resident_id <> NEW.resident_id;

    IF v_going_count >= v_max THEN
      NEW.status := 'waitlisted';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_check_dinner_gathering_capacity
  BEFORE INSERT OR UPDATE ON event_rsvps
  FOR EACH ROW EXECUTE FUNCTION check_dinner_gathering_capacity();
```

### 27.4 RLS

```sql
ALTER TABLE dinner_gatherings ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON dinner_gatherings
  USING (
    event_id IN (
      SELECT id FROM events
      WHERE community_id = current_setting('app.current_community_id', true)::uuid
    )
  );
```

### 27.5 הרחבות עתידיות (לא נדרשות עכשיו)

תזכורת למארחת אם קרובים לתאריך ועדיין פחות מ-`min_participants`; מנגנון דיווח בטיחות קליל על הרישום.

---

## 28. חיפוש וסינון ארוחות מקבילות

### 28.1 "מקומות פנויים" הוא נגזר, לא שדה מאוחסן

```sql
CREATE VIEW dinner_gathering_availability AS
SELECT
  e.id AS event_id,
  e.community_id,
  e.title,
  e.starts_at,
  e.location,
  dg.host_resident_id,
  dg.meal_type,
  dg.theme_description,
  dg.min_participants,
  dg.max_participants,
  dg.status,
  dg.max_participants - COALESCE(gc.going_count, 0) AS spots_available
FROM events e
JOIN dinner_gatherings dg ON dg.event_id = e.id
LEFT JOIN LATERAL (
  SELECT count(*) AS going_count
  FROM event_rsvps er
  WHERE er.event_id = e.id AND er.status = 'going'
) gc ON true;
```

### 28.2 שאילתת החיפוש

```sql
SELECT * FROM dinner_gathering_availability
WHERE community_id = :community_id
  AND status = 'open'
  AND (:date IS NULL OR starts_at::date = :date)
  AND (:theme_query IS NULL OR theme_description ILIKE '%' || :theme_query || '%')
  AND (:min_spots IS NULL OR spots_available >= :min_spots)
ORDER BY starts_at;
```

חיפוש קונספט סובלני לטעויות כתיב ("איטלקי" מול "איטלקית") — `pg_trgm` על `theme_description`, אותו פתרון כמו חיפוש בעלי מקצוע (סעיף 12).

### 28.3 עובד גם עם הרבה ארוחות במקביל

`dinner_gatherings` היא טבלה רגילה בלי הגבלה על כמה שורות פתוחות בו-זמנית; ה-view מחשב זמינות לכל ארוחה בנפרד. עשר ארוחות באותו שבוע = עשר שורות, אין נעילה הדדית.

---

## סטטוס יישום בפרויקט UPPER

| רכיב | סטטוס |
|---|---|
| `community_resources`, `resource_bookings` (חדש), `resource_blackout_periods` | ✅ migration נכתב: [20260914120000_community_resources_booking.sql](../supabase/migrations/20260914120000_community_resources_booking.sql) |
| טבלאות ישנות `shared_resources` / `resource_bookings` (מ-20260906130000) | הוסבו לשם `..._deprecated` באותה migration — לא נמחקו, לא היה להן UI מעולם |
| `vehicle_details`, `vehicle_trip_logs` + טריגר סנכרון + bucket תמונות | ✅ migration נכתב: [20260914130000_vehicles_potluck_dinners.sql](../supabase/migrations/20260914130000_vehicles_potluck_dinners.sql) |
| `potluck_items`, `event_rsvps.notes`, הרחבת `reactions.target_type` | ✅ אותו קובץ |
| `dinner_gatherings`, רשימת המתנה אוטומטית, `dinner_gathering_availability` view | ✅ אותו קובץ |
| מסכי ניהול/הזמנה ב-Retool ו-Lovable (משאבים, רכבים, פוטלאק, ארוחות היכרות) | טרם נבנו |
| החלטות מוצר פתוחות מסעיף 25.3 (חובת צילום, התראת נזק, מדיניות אופליין) | טרם הוחלטו |
