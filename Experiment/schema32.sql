


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."admin_delete_comment"("p_comment_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_author uuid;
    v_parent uuid;
    v_was_deleted boolean;
    v_child_count int;
    v_walk uuid;
    v_walk_parent uuid;
    v_walk_deleted boolean;
BEGIN
    SELECT author_id, parent_id, is_deleted INTO v_author, v_parent, v_was_deleted
    FROM public.comments
    WHERE id = p_comment_id;

    IF v_author IS NULL THEN
        RAISE EXCEPTION 'Comment not found';
    END IF;

    SELECT count(*) INTO v_child_count
    FROM public.comments
    WHERE parent_id = p_comment_id;

    IF v_child_count = 0 THEN
        -- No thread beneath it: remove entirely, like it was never there.
        DELETE FROM public.comments WHERE id = p_comment_id;

        -- Walk up the parent chain and clean up any ancestors that were
        -- already soft-deleted placeholders and are now childless too.
        v_walk := v_parent;
        WHILE v_walk IS NOT NULL LOOP
            SELECT is_deleted, parent_id INTO v_walk_deleted, v_walk_parent
            FROM public.comments WHERE id = v_walk;

            EXIT WHEN v_walk_deleted IS NOT TRUE;
            EXIT WHEN EXISTS (SELECT 1 FROM public.comments WHERE parent_id = v_walk);

            DELETE FROM public.comments WHERE id = v_walk;
            v_walk := v_walk_parent;
        END LOOP;
    ELSE
        -- Has a thread beneath it: soft-delete, replies stay untouched.
        UPDATE public.comments
           SET is_deleted = true, body = ''
         WHERE id = p_comment_id;
    END IF;

    -- Resolve every pending report on this comment, not just one.
    UPDATE public.comment_reports
       SET resolved_at = now(), resolved_action = 'deleted'
     WHERE comment_id = p_comment_id
       AND resolved_at IS NULL;

    -- Fire the warning only on the transition into deleted state.
    IF v_was_deleted IS NOT TRUE THEN
        INSERT INTO public.notifications (user_id, type, body_preview)
        VALUES (
            v_author,
            'moderation_warning',
            'Comment Removed|||' ||
            'We reviewed a report and confirmed that your comment violated our Community Guidelines.' || chr(10) || chr(10) ||
            'Repeated violations may result in temporary restrictions or permanent suspension of your account.' || chr(10) || chr(10) ||
            'Please ensure future comments remain respectful and comply with our Community Guidelines.'
        );
    END IF;
END;
$$;


ALTER FUNCTION "public"."admin_delete_comment"("p_comment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."broadcast_announcement"("p_post_id" "uuid", "p_title" "text", "p_body" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_actor uuid := auth.uid();
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.gpa_data WHERE id = v_actor AND role = 'admin') THEN
    RAISE EXCEPTION 'Only admins can broadcast announcements';
  END IF;

  INSERT INTO public.notifications (user_id, actor_id, type, post_id, body_preview)
  SELECT g.id, v_actor, 'announcement', p_post_id, left(p_title, 200) || '|||' || left(p_body, 2000)
  FROM public.gpa_data g
  WHERE g.id <> v_actor
  ON CONFLICT (post_id, user_id) WHERE (type = 'announcement') DO NOTHING;
END;
$$;


ALTER FUNCTION "public"."broadcast_announcement"("p_post_id" "uuid", "p_title" "text", "p_body" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."broadcast_daily_tip"("p_post_id" "uuid", "p_title" "text", "p_body" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
                                                                    DECLARE
                                                                      v_actor uuid := auth.uid();
                                                                      BEGIN
                                                                        IF v_actor IS NULL THEN
                                                                            RAISE EXCEPTION 'Not authenticated';
                                                                              END IF;

                                                                                IF NOT EXISTS (SELECT 1 FROM public.gpa_data WHERE id = v_actor AND role = 'admin') THEN
                                                                                    RAISE EXCEPTION 'Only admins can broadcast daily tips';
                                                                                      END IF;

                                                                                        INSERT INTO public.notifications (user_id, actor_id, type, post_id, body_preview)
                                                                                          SELECT g.id, v_actor, 'daily_tip', p_post_id, left(p_title, 200) || '|||' || left(p_body, 2000)
                                                                                            FROM public.gpa_data g
                                                                                              WHERE g.id <> v_actor
                                                                                                ON CONFLICT (post_id, user_id) WHERE (type = 'daily_tip') DO NOTHING;
                                                                                                END;
                                                                                                $$;


ALTER FUNCTION "public"."broadcast_daily_tip"("p_post_id" "uuid", "p_title" "text", "p_body" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_and_log_reset_attempt"("p_email" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
                          DECLARE
                            v_email text := lower(trim(p_email));
                              v_count int;
                                v_start timestamptz;
                                BEGIN
                                  SELECT attempt_count, window_start INTO v_count, v_start
                                      FROM public.password_reset_attempts WHERE email = v_email FOR UPDATE;

                                        IF v_start IS NULL THEN
                                            INSERT INTO public.password_reset_attempts (email, attempt_count, window_start)
                                                VALUES (v_email, 1, now());
                                                    RETURN true;
                                                      END IF;

                                                        IF now() - v_start > interval '1 hour' THEN
                                                            UPDATE public.password_reset_attempts
                                                                  SET attempt_count = 1, window_start = now()
                                                                        WHERE email = v_email;
                                                                            RETURN true;
                                                                              END IF;

                                                                                IF v_count >= 3 THEN
                                                                                    RETURN false;
                                                                                      END IF;

                                                                                        UPDATE public.password_reset_attempts
                                                                                            SET attempt_count = attempt_count + 1
                                                                                                WHERE email = v_email;
                                                                                                  RETURN true;
                                                                                                  END;
                                                                                                  $$;


ALTER FUNCTION "public"."check_and_log_reset_attempt"("p_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clear_all_notifications"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
              BEGIN
                UPDATE public.gpa_data
                    SET notifications_cleared_before = now()
                        WHERE id = auth.uid();
                        END;
                        $$;


ALTER FUNCTION "public"."clear_all_notifications"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_comment"("p_comment_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  DECLARE
    v_uid uuid := auth.uid();
      v_author uuid;
        v_parent uuid;
          v_child_count int;
            v_walk uuid;
              v_walk_parent uuid;
                v_walk_deleted boolean;
                BEGIN
                  IF v_uid IS NULL THEN
                      RAISE EXCEPTION 'Not authenticated';
                        END IF;

                          SELECT author_id, parent_id INTO v_author, v_parent
                            FROM public.comments
                              WHERE id = p_comment_id;

                                IF v_author IS NULL THEN
                                    RAISE EXCEPTION 'Comment not found';
                                      END IF;

                                        IF v_author <> v_uid THEN
                                            RAISE EXCEPTION 'Not authorized';
                                              END IF;

                                                SELECT count(*) INTO v_child_count
                                                  FROM public.comments
                                                    WHERE parent_id = p_comment_id;

                                                      IF v_child_count = 0 THEN
                                                          -- No thread beneath it: remove entirely, like it was never there.
                                                              DELETE FROM public.comments WHERE id = p_comment_id;

                                                                  -- Walk up the parent chain and clean up any ancestors that were
                                                                      -- already soft-deleted placeholders and are now childless too.
                                                                          v_walk := v_parent;
                                                                              WHILE v_walk IS NOT NULL LOOP
                                                                                    SELECT is_deleted, parent_id INTO v_walk_deleted, v_walk_parent
                                                                                          FROM public.comments WHERE id = v_walk;

                                                                                                EXIT WHEN v_walk_deleted IS NOT TRUE;
                                                                                                      EXIT WHEN EXISTS (SELECT 1 FROM public.comments WHERE parent_id = v_walk);

                                                                                                            DELETE FROM public.comments WHERE id = v_walk;
                                                                                                                  v_walk := v_walk_parent;
                                                                                                                      END LOOP;
                                                                                                                        ELSE
                                                                                                                            -- Has a thread beneath it: soft-delete, replies stay untouched.
                                                                                                                                UPDATE public.comments
                                                                                                                                    SET is_deleted = true, body = ''
                                                                                                                                        WHERE id = p_comment_id;
                                                                                                                                          END IF;
                                                                                                                                          END;
                                                                                                                                          $$;


ALTER FUNCTION "public"."delete_comment"("p_comment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dismiss_comment_reports"("p_comment_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    UPDATE public.comment_reports
       SET resolved_at = now(), resolved_action = 'dismissed'
     WHERE comment_id = p_comment_id
       AND resolved_at IS NULL;
END;
$$;


ALTER FUNCTION "public"."dismiss_comment_reports"("p_comment_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."comments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "post_id" "uuid" NOT NULL,
    "author_id" "uuid" NOT NULL,
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "parent_id" "uuid",
    "upvotes" integer DEFAULT 0 NOT NULL,
    "downvotes" integer DEFAULT 0 NOT NULL,
    "is_deleted" boolean DEFAULT false NOT NULL,
    "edited_at" timestamp with time zone
);


ALTER TABLE "public"."comments" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."edit_comment"("p_comment_id" "uuid", "p_body" "text") RETURNS "public"."comments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
              DECLARE
                v_uid uuid := auth.uid();
                  v_author uuid;
                    v_created timestamptz;
                      v_is_deleted boolean;
                        v_row public.comments;
                        BEGIN
                          IF v_uid IS NULL THEN
                              RAISE EXCEPTION 'Not authenticated';
                                END IF;

                                  IF p_body IS NULL OR length(btrim(p_body)) = 0 THEN
                                      RAISE EXCEPTION 'Comment cannot be empty';
                                        END IF;

                                          SELECT author_id, created_at, is_deleted INTO v_author, v_created, v_is_deleted
                                            FROM public.comments
                                              WHERE id = p_comment_id;

                                                IF v_author IS NULL THEN
                                                    RAISE EXCEPTION 'Comment not found';
                                                      END IF;

                                                        IF v_author <> v_uid THEN
                                                            RAISE EXCEPTION 'Not authorized';
                                                              END IF;

                                                                IF v_is_deleted THEN
                                                                    RAISE EXCEPTION 'Cannot edit a deleted comment';
                                                                      END IF;

                                                                        -- Server-side clock is the only clock that counts here.
                                                                          IF now() - v_created > interval '5 minutes' THEN
                                                                              RAISE EXCEPTION 'Edit window has expired';
                                                                                END IF;

                                                                                  UPDATE public.comments
                                                                                      SET body = btrim(p_body), edited_at = now()
                                                                                          WHERE id = p_comment_id
                                                                                              RETURNING * INTO v_row;

                                                                                                RETURN v_row;
                                                                                                END;
                                                                                                $$;


ALTER FUNCTION "public"."edit_comment"("p_comment_id" "uuid", "p_body" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."credit_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "delta" integer NOT NULL,
    "balance_after" integer NOT NULL,
    "reason" "text" NOT NULL,
    "reference_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reason_label" "text" GENERATED ALWAYS AS (
CASE "reason"
    WHEN 'signup_bonus'::"text" THEN 'Signup bonus'::"text"
    WHEN 'signup_ledger_marker'::"text" THEN 'Account created'::"text"
    WHEN 'unlock_post'::"text" THEN 'Unlocked post'::"text"
    WHEN 'comment_post'::"text" THEN 'Posted comment'::"text"
    WHEN 'profile_save'::"text" THEN 'Saved profile'::"text"
    WHEN 'course_add'::"text" THEN 'Added course'::"text"
    WHEN 'autosave_batch'::"text" THEN 'Course autosave'::"text"
    WHEN 'course_import'::"text" THEN 'Imported courses'::"text"
    WHEN 'semester_note'::"text" THEN 'Saved semester note'::"text"
    WHEN 'admin_grant'::"text" THEN 'Admin credit grant'::"text"
    WHEN 'purchase'::"text" THEN 'Credit purchase'::"text"
    WHEN 'admin_topup'::"text" THEN 'Admin top-up'::"text"
    WHEN 'admin_bonus'::"text" THEN 'Admin bonus'::"text"
    ELSE "reason"
END) STORED,
    CONSTRAINT "credit_transactions_reason_check" CHECK (("reason" = ANY (ARRAY['signup_bonus'::"text", 'signup_ledger_marker'::"text", 'unlock_post'::"text", 'comment_post'::"text", 'profile_save'::"text", 'course_add'::"text", 'autosave_batch'::"text", 'course_import'::"text", 'semester_note'::"text", 'admin_grant'::"text", 'purchase'::"text", 'admin_topup'::"text", 'admin_bonus'::"text"])))
);


ALTER TABLE "public"."credit_transactions" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_credit_history"("p_limit" integer DEFAULT 30, "p_before_created_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_before_id" "uuid" DEFAULT NULL::"uuid", "p_direction" "text" DEFAULT NULL::"text", "p_since" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_search" "text" DEFAULT NULL::"text") RETURNS SETOF "public"."credit_transactions"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
                                                                                                                            SELECT *
                                                                                                                                  FROM public.credit_transactions
                                                                                                                                        WHERE user_id = auth.uid()
                                                                                                                                                AND (
                                                                                                                                                          p_before_created_at IS NULL
                                                                                                                                                                    OR (created_at, id) < (p_before_created_at, p_before_id)
                                                                                                                                                                            )
                                                                                                                                                                                    AND (
                                                                                                                                                                                              p_direction IS NULL
                                                                                                                                                                                                        OR (p_direction = 'spent' AND delta < 0)
                                                                                                                                                                                                                  OR (p_direction = 'topup' AND delta > 0)
                                                                                                                                                                                                                          )
                                                                                                                                                                                                                                  AND (p_since IS NULL OR created_at >= p_since)
                                                                                                                                                                                                                                          AND (p_search IS NULL OR p_search = '' OR reason_label ILIKE '%' || p_search || '%')
                                                                                                                                                                                                                                                ORDER BY created_at DESC, id DESC
                                                                                                                                                                                                                                                      LIMIT LEAST(p_limit, 100);
                                                                                                                                                                                                                                                          $$;


ALTER FUNCTION "public"."get_credit_history"("p_limit" integer, "p_before_created_at" timestamp with time zone, "p_before_id" "uuid", "p_direction" "text", "p_since" timestamp with time zone, "p_search" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."grant_credits"("p_user_id" "uuid", "p_amount" integer, "p_reason" "text", "p_reference_id" "uuid" DEFAULT NULL::"uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_new_balance integer;
    v_notif_type  text;
    v_notif_msg   text;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid amount';
    END IF;

    -- Idempotency: if this reference_id was already used for a grant,
    -- return the current balance without granting again. Checked BEFORE
    -- the UPDATE so a duplicate call never mutates credits.balance.
    -- Scoped to grant reasons only, matching the partial unique index —
    -- reference_id is reused non-uniquely on the spend path (e.g. post_id
    -- in comment_post) and must not be treated as unique here.
    IF p_reference_id IS NOT NULL
       AND p_reason IN ('admin_topup', 'admin_bonus', 'signup_bonus')
       AND EXISTS (
           SELECT 1 FROM public.credit_transactions
           WHERE reference_id = p_reference_id
             AND reason IN ('admin_topup', 'admin_bonus', 'signup_bonus')
       )
    THEN
        SELECT balance INTO v_new_balance FROM public.credits WHERE id = p_user_id;
        RETURN v_new_balance;
    END IF;

    UPDATE public.credits
       SET balance = balance + p_amount,
           updated_at = now()
     WHERE id = p_user_id
     RETURNING balance INTO v_new_balance;

    IF v_new_balance IS NULL THEN
        RAISE EXCEPTION 'No credit row for user';
    END IF;

    -- Partial unique index (credit_transactions_grant_reference_id_unique,
    -- from the corrected schema24.sql) is the atomic backstop for the race
    -- the EXISTS check alone can't close.
    BEGIN
        INSERT INTO public.credit_transactions (user_id, delta, balance_after, reason, reference_id)
        VALUES (p_user_id, p_amount, v_new_balance, p_reason, p_reference_id);
    EXCEPTION WHEN unique_violation THEN
        -- Lost the race: another concurrent call already logged this
        -- reference_id for a grant reason. Roll back this call's balance
        -- mutation.
        UPDATE public.credits
           SET balance = balance - p_amount,
               updated_at = now()
         WHERE id = p_user_id
         RETURNING balance INTO v_new_balance;
        RETURN v_new_balance;
    END;

    IF p_reason = 'admin_topup' THEN
        v_notif_type := 'credit_topup';
        v_notif_msg  := '+' || p_amount || ' credits';
    ELSIF p_reason = 'admin_bonus' THEN
        v_notif_type := 'credit_bonus';
        v_notif_msg  := '+' || p_amount || ' credits';
    ELSIF p_reason = 'signup_bonus' THEN
        v_notif_type := 'credit_signup_bonus';
        v_notif_msg  := '+' || p_amount || ' credits';
    END IF;

    IF v_notif_type IS NOT NULL THEN
        INSERT INTO public.notifications (user_id, type, body_preview)
        VALUES (p_user_id, v_notif_type, v_notif_msg);
    END IF;

    RETURN v_new_balance;
END;
$$;


ALTER FUNCTION "public"."grant_credits"("p_user_id" "uuid", "p_amount" integer, "p_reason" "text", "p_reference_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user_credits"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    INSERT INTO public.credits (id, balance) VALUES (new.id, 0);
    INSERT INTO public.credit_transactions (user_id, delta, balance_after, reason)
    VALUES (new.id, 0, 0, 'signup_ledger_marker');
    RETURN new;
END;
$$;


ALTER FUNCTION "public"."handle_new_user_credits"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_all_notifications_read"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
                                                                                                                                                                                    BEGIN
                                                                                                                                                                                        UPDATE public.notifications
                                                                                                                                                                                            SET is_read = true
                                                                                                                                                                                                WHERE user_id = auth.uid() AND is_read = false;
                                                                                                                                                                                                END;
                                                                                                                                                                                                $$;


ALTER FUNCTION "public"."mark_all_notifications_read"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_push"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_secret text;
BEGIN
  BEGIN
    SELECT decrypted_secret INTO v_secret
    FROM vault.decrypted_secrets
    WHERE name = 'push_webhook_secret';

    PERFORM net.http_post(
      url := 'https://kacsnofbokruxapwfhwh.supabase.co/functions/v1/push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-webhook-secret', v_secret
      ),
      body := jsonb_build_object(
        'type', 'INSERT',
        'table', 'notifications',
        'schema', 'public',
        'record', to_jsonb(NEW)
      )
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'notify_push: push delivery failed for notification %: %', NEW.id, SQLERRM;
  END;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."notify_push"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_reply"("p_comment_id" "uuid", "p_parent_id" "uuid", "p_post_id" "uuid", "p_body" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_actor uuid := auth.uid();
  v_parent_author uuid;
BEGIN
  IF v_actor IS NULL THEN RETURN; END IF;

  SELECT author_id INTO v_parent_author
  FROM public.comments
  WHERE id = p_parent_id;

  IF v_parent_author IS NULL OR v_parent_author = v_actor THEN
    RETURN; -- no self-notifications
  END IF;

  INSERT INTO public.notifications (user_id, actor_id, type, post_id, comment_id, body_preview)
  VALUES (v_parent_author, v_actor, 'reply', p_post_id, p_comment_id, left(p_body, 140))
  ON CONFLICT (comment_id) WHERE (type = 'reply') DO NOTHING;
END;
$$;


ALTER FUNCTION "public"."notify_reply"("p_comment_id" "uuid", "p_parent_id" "uuid", "p_post_id" "uuid", "p_body" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text") RETURNS "public"."comments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
                                                                                                                                                                                                                                  DECLARE v_uid uuid := auth.uid(); v_row public.comments;
                                                                                                                                                                                                                                  BEGIN
                                                                                                                                                                                                                                    IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;
                                                                                                                                                                                                                                      PERFORM public.spend_credits(1, 'comment_post', p_post_id);
                                                                                                                                                                                                                                        INSERT INTO public.comments (post_id, author_id, body)
                                                                                                                                                                                                                                              VALUES (p_post_id, v_uid, p_body)
                                                                                                                                                                                                                                                    RETURNING * INTO v_row;
                                                                                                                                                                                                                                                      RETURN v_row;
                                                                                                                                                                                                                                                      END;
                                                                                                                                                                                                                                                      $$;


ALTER FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text", "p_parent_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."comments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
                                                                                                                                                                                                                                                                  DECLARE
                                                                                                                                                                                                                                                                      v_uid uuid := auth.uid();
                                                                                                                                                                                                                                                                          v_row public.comments;
                                                                                                                                                                                                                                                                          BEGIN
                                                                                                                                                                                                                                                                              IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated'; END IF;

                                                                                                                                                                                                                                                                                  -- If replying, confirm parent belongs to the same post
                                                                                                                                                                                                                                                                                      IF p_parent_id IS NOT NULL THEN
                                                                                                                                                                                                                                                                                              IF NOT EXISTS (
                                                                                                                                                                                                                                                                                                          SELECT 1 FROM public.comments
                                                                                                                                                                                                                                                                                                                      WHERE id = p_parent_id AND post_id = p_post_id
                                                                                                                                                                                                                                                                                                                              ) THEN
                                                                                                                                                                                                                                                                                                                                          RAISE EXCEPTION 'Invalid parent comment';
                                                                                                                                                                                                                                                                                                                                                  END IF;
                                                                                                                                                                                                                                                                                                                                                      END IF;

                                                                                                                                                                                                                                                                                                                                                          PERFORM public.spend_credits(1, 'comment_post', p_post_id);

                                                                                                                                                                                                                                                                                                                                                              INSERT INTO public.comments (post_id, author_id, body, parent_id)
                                                                                                                                                                                                                                                                                                                                                                      VALUES (p_post_id, v_uid, p_body, p_parent_id)
                                                                                                                                                                                                                                                                                                                                                                              RETURNING * INTO v_row;

                                                                                                                                                                                                                                                                                                                                                                                  RETURN v_row;
                                                                                                                                                                                                                                                                                                                                                                                  END;
                                                                                                                                                                                                                                                                                                                                                                                  $$;


ALTER FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text", "p_parent_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."report_comment"("p_comment_id" "uuid", "p_reason" "text", "p_other_text" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
    v_uid uuid := auth.uid();
    v_author uuid;
BEGIN
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    SELECT author_id INTO v_author
    FROM public.comments
    WHERE id = p_comment_id AND is_deleted = false;

    IF v_author IS NULL THEN
        RAISE EXCEPTION 'Comment not found';
    END IF;

    IF v_author = v_uid THEN
        RAISE EXCEPTION 'Cannot report your own comment';
    END IF;

    IF p_reason = 'other' AND (p_other_text IS NULL OR length(btrim(p_other_text)) = 0) THEN
        RAISE EXCEPTION 'Please describe the reason';
    END IF;

    INSERT INTO public.comment_reports (comment_id, reporter_id, reason, other_text)
    VALUES (
        p_comment_id,
        v_uid,
        p_reason,
        CASE WHEN p_reason = 'other' THEN left(btrim(p_other_text), 500) ELSE NULL END
    )
    ON CONFLICT (comment_id, reporter_id) DO NOTHING;
END;
$$;


ALTER FUNCTION "public"."report_comment"("p_comment_id" "uuid", "p_reason" "text", "p_other_text" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."spend_credits"("p_cost" integer, "p_reason" "text", "p_reference_id" "uuid" DEFAULT NULL::"uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
                                                                                            DECLARE
                                                                                                v_uid uuid := auth.uid();
                                                                                                    v_new_balance integer;
                                                                                                    BEGIN
                                                                                                        IF v_uid IS NULL THEN
                                                                                                                RAISE EXCEPTION 'Not authenticated';
                                                                                                                    END IF;

                                                                                                                        IF p_cost IS NULL OR p_cost <= 0 THEN
                                                                                                                                RAISE EXCEPTION 'Invalid cost';
                                                                                                                                    END IF;

                                                                                                                                        UPDATE public.credits
                                                                                                                                                SET balance = balance - p_cost,
                                                                                                                                                            updated_at = now()
                                                                                                                                                                    WHERE id = v_uid
                                                                                                                                                                              AND balance >= p_cost
                                                                                                                                                                                      RETURNING balance INTO v_new_balance;

                                                                                                                                                                                          IF v_new_balance IS NULL THEN
                                                                                                                                                                                                  RAISE EXCEPTION 'Insufficient credits';
                                                                                                                                                                                                      END IF;

                                                                                                                                                                                                          INSERT INTO public.credit_transactions (user_id, delta, balance_after, reason, reference_id)
                                                                                                                                                                                                                  VALUES (v_uid, -p_cost, v_new_balance, p_reason, p_reference_id);

                                                                                                                                                                                                                      RETURN v_new_balance;
                                                                                                                                                                                                                      END;
                                                                                                                                                                                                                      $$;


ALTER FUNCTION "public"."spend_credits"("p_cost" integer, "p_reason" "text", "p_reference_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_course_catalogs_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
                begin
                  new.updated_at = now();
                    return new;
                    end;
                    $$;


ALTER FUNCTION "public"."touch_course_catalogs_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."unlock_post"("p_post_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
                                                                                                                                                                                                                                                                                                                                                                                          DECLARE
                                                                                                                                                                                                                                                                                                                                                                                              v_user_id uuid := auth.uid();
                                                                                                                                                                                                                                                                                                                                                                                                  v_cost    integer;
                                                                                                                                                                                                                                                                                                                                                                                                      v_balance integer;
                                                                                                                                                                                                                                                                                                                                                                                                          v_already boolean;
                                                                                                                                                                                                                                                                                                                                                                                                          BEGIN
                                                                                                                                                                                                                                                                                                                                                                                                              IF v_user_id IS NULL THEN
                                                                                                                                                                                                                                                                                                                                                                                                                      RAISE EXCEPTION 'not_authenticated';
                                                                                                                                                                                                                                                                                                                                                                                                                          END IF;

                                                                                                                                                                                                                                                                                                                                                                                                                              SELECT credit_cost INTO v_cost
                                                                                                                                                                                                                                                                                                                                                                                                                                      FROM posts
                                                                                                                                                                                                                                                                                                                                                                                                                                              WHERE id = p_post_id AND is_premium = true;

                                                                                                                                                                                                                                                                                                                                                                                                                                                  IF NOT FOUND THEN
                                                                                                                                                                                                                                                                                                                                                                                                                                                          RAISE EXCEPTION 'not_premium_or_not_found';
                                                                                                                                                                                                                                                                                                                                                                                                                                                              END IF;

                                                                                                                                                                                                                                                                                                                                                                                                                                                                  SELECT EXISTS (
                                                                                                                                                                                                                                                                                                                                                                                                                                                                          SELECT 1 FROM post_unlocks
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  WHERE post_id = p_post_id AND user_id = v_user_id
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      ) INTO v_already;

                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          IF v_already THEN
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  SELECT balance INTO v_balance FROM credits WHERE id = v_user_id;
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          RETURN COALESCE(v_balance, 0);
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              END IF;

                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  SELECT spend_credits(v_cost, 'unlock_post', p_post_id) INTO v_balance;

                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      INSERT INTO post_unlocks (post_id, user_id)
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              VALUES (p_post_id, v_user_id);

                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  RETURN v_balance;
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  END;
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  $$;


ALTER FUNCTION "public"."unlock_post"("p_post_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
                      BEGIN
                        NEW.updated_at = NOW();
                          RETURN NEW;
                          END;
                          $$;


ALTER FUNCTION "public"."update_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."vote_comment"("p_comment_id" "uuid", "p_vote" smallint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
      DECLARE
        v_uid      uuid := auth.uid();
          v_existing smallint;
            v_result   jsonb;
            BEGIN
              IF v_uid IS NULL THEN
                  RAISE EXCEPTION 'Not authenticated';
                    END IF;

                      IF p_vote NOT IN (1, -1) THEN
                          RAISE EXCEPTION 'Invalid vote value';
                            END IF;

                              -- Check for existing vote
                                SELECT vote INTO v_existing
                                  FROM public.comment_votes
                                    WHERE comment_id = p_comment_id AND user_id = v_uid;

                                      IF NOT FOUND THEN
                                          -- No prior vote: insert and increment
                                              INSERT INTO public.comment_votes (comment_id, user_id, vote)
                                                  VALUES (p_comment_id, v_uid, p_vote);

                                                      UPDATE public.comments
                                                          SET upvotes   = upvotes   + CASE WHEN p_vote =  1 THEN 1 ELSE 0 END,
                                                                  downvotes = downvotes + CASE WHEN p_vote = -1 THEN 1 ELSE 0 END
                                                                      WHERE id = p_comment_id;

                                                                        ELSIF v_existing = p_vote THEN
                                                                            -- Same vote: toggle off, decrement
                                                                                DELETE FROM public.comment_votes
                                                                                    WHERE comment_id = p_comment_id AND user_id = v_uid;

                                                                                        UPDATE public.comments
                                                                                            SET upvotes   = upvotes   - CASE WHEN p_vote =  1 THEN 1 ELSE 0 END,
                                                                                                    downvotes = downvotes - CASE WHEN p_vote = -1 THEN 1 ELSE 0 END
                                                                                                        WHERE id = p_comment_id;

                                                                                                          ELSE
                                                                                                              -- Opposite vote: update row, swap counters
                                                                                                                  UPDATE public.comment_votes
                                                                                                                      SET vote = p_vote, created_at = now()
                                                                                                                          WHERE comment_id = p_comment_id AND user_id = v_uid;

                                                                                                                              UPDATE public.comments
                                                                                                                                  SET upvotes   = upvotes   + CASE WHEN p_vote =  1 THEN 1 ELSE -1 END,
                                                                                                                                          downvotes = downvotes + CASE WHEN p_vote = -1 THEN 1 ELSE -1 END
                                                                                                                                              WHERE id = p_comment_id;

                                                                                                                                                END IF;

                                                                                                                                                  -- Return updated counts + user's current vote state (null = no vote)
                                                                                                                                                    SELECT jsonb_build_object(
                                                                                                                                                        'upvotes',   c.upvotes,
                                                                                                                                                            'downvotes', c.downvotes,
                                                                                                                                                                'user_vote', cv.vote
                                                                                                                                                                  )
                                                                                                                                                                    INTO v_result
                                                                                                                                                                      FROM public.comments c
                                                                                                                                                                        LEFT JOIN public.comment_votes cv
                                                                                                                                                                            ON cv.comment_id = c.id AND cv.user_id = v_uid
                                                                                                                                                                              WHERE c.id = p_comment_id;

                                                                                                                                                                                RETURN v_result;
                                                                                                                                                                                END;
                                                                                                                                                                                $$;


ALTER FUNCTION "public"."vote_comment"("p_comment_id" "uuid", "p_vote" smallint) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."avatars" (
    "id" "text" NOT NULL,
    "path" "text" NOT NULL,
    "url" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."avatars" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bookmarks" (
    "user_id" "uuid" NOT NULL,
    "post_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."bookmarks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comment_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "comment_id" "uuid" NOT NULL,
    "reporter_id" "uuid" NOT NULL,
    "reason" "text" NOT NULL,
    "other_text" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "resolved_action" "text",
    CONSTRAINT "comment_reports_other_text_required" CHECK ((("reason" <> 'other'::"text") OR (("other_text" IS NOT NULL) AND ("length"("btrim"("other_text")) > 0)))),
    CONSTRAINT "comment_reports_reason_check" CHECK (("reason" = ANY (ARRAY['harassment'::"text", 'hate_speech'::"text", 'spam'::"text", 'misinformation'::"text", 'inappropriate'::"text", 'impersonation'::"text", 'other'::"text"]))),
    CONSTRAINT "comment_reports_resolved_action_check" CHECK ((("resolved_action" IS NULL) OR ("resolved_action" = ANY (ARRAY['deleted'::"text", 'dismissed'::"text"]))))
);


ALTER TABLE "public"."comment_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comment_votes" (
    "comment_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "vote" smallint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "comment_votes_value" CHECK (("vote" = ANY (ARRAY[1, '-1'::integer])))
);


ALTER TABLE "public"."comment_votes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."course_catalogs" (
    "id" bigint NOT NULL,
    "department" "text" NOT NULL,
    "year" integer NOT NULL,
    "semester" "text" NOT NULL,
    "level" integer NOT NULL,
    "courses" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "course_catalogs_level_check" CHECK ((("level" >= 1) AND ("level" <= 5))),
    CONSTRAINT "course_catalogs_semester_check" CHECK (("semester" = ANY (ARRAY['1st'::"text", '2nd'::"text"]))),
    CONSTRAINT "course_catalogs_year_check" CHECK ((("year" >= 2000) AND ("year" <= 2100)))
);


ALTER TABLE "public"."course_catalogs" OWNER TO "postgres";


ALTER TABLE "public"."course_catalogs" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."course_catalogs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."credits" (
    "id" "uuid" NOT NULL,
    "balance" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."credits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."device_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "fcm_token" "text" NOT NULL,
    "platform" "text" DEFAULT 'android'::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."device_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gpa_data" (
    "id" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "department" "text",
    "semesters" "jsonb" DEFAULT '{}'::"jsonb",
    "courses" "jsonb" DEFAULT '{}'::"jsonb",
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "notes" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "username" "text",
    "full_name" "text",
    "avatar_id" "text",
    "level" smallint,
    "role" "text" DEFAULT 'student'::"text" NOT NULL,
    "verified" boolean DEFAULT false NOT NULL,
    "admission_year" smallint,
    "notifications_cleared_before" timestamp with time zone,
    CONSTRAINT "gpa_data_admission_year_check" CHECK ((("admission_year" IS NULL) OR (("admission_year" >= 2000) AND ("admission_year" <= 2100)))),
    CONSTRAINT "gpa_data_level_check" CHECK ((("level" >= 1) AND ("level" <= 5))),
    CONSTRAINT "gpa_data_role_check" CHECK (("role" = ANY (ARRAY['student'::"text", 'contributor'::"text", 'admin'::"text"])))
);


ALTER TABLE "public"."gpa_data" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."news_images" (
    "id" "text" NOT NULL,
    "path" "text" NOT NULL,
    "url" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."news_images" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "actor_id" "uuid",
    "type" "text" DEFAULT 'reply'::"text" NOT NULL,
    "post_id" "uuid",
    "comment_id" "uuid",
    "body_preview" "text",
    "is_read" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."password_reset_attempts" (
    "email" "text" NOT NULL,
    "attempt_count" integer DEFAULT 1 NOT NULL,
    "window_start" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."password_reset_attempts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."post_unlocks" (
    "user_id" "uuid" NOT NULL,
    "post_id" "uuid" NOT NULL,
    "unlocked_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."post_unlocks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."posts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "author_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "tags" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "source_links" "text"[] DEFAULT '{}'::"text"[],
    "comments_restricted" boolean DEFAULT false NOT NULL,
    "is_premium" boolean DEFAULT false NOT NULL,
    "credit_cost" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "image_url" "text",
    "post_type" "text" DEFAULT 'news'::"text" NOT NULL,
    CONSTRAINT "posts_post_type_check" CHECK (("post_type" = ANY (ARRAY['news'::"text", 'announcement'::"text", 'daily_tip'::"text"])))
);


ALTER TABLE "public"."posts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."reactions" (
    "post_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "reactions_type_check" CHECK (("type" = ANY (ARRAY['like'::"text", 'dislike'::"text"])))
);


ALTER TABLE "public"."reactions" OWNER TO "postgres";


ALTER TABLE ONLY "public"."avatars"
    ADD CONSTRAINT "avatars_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bookmarks"
    ADD CONSTRAINT "bookmarks_pkey" PRIMARY KEY ("user_id", "post_id");



ALTER TABLE ONLY "public"."comment_reports"
    ADD CONSTRAINT "comment_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."comment_reports"
    ADD CONSTRAINT "comment_reports_unique_per_reporter" UNIQUE ("comment_id", "reporter_id");



ALTER TABLE ONLY "public"."comment_votes"
    ADD CONSTRAINT "comment_votes_pkey" PRIMARY KEY ("comment_id", "user_id");



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."course_catalogs"
    ADD CONSTRAINT "course_catalogs_department_year_semester_level_key" UNIQUE ("department", "year", "semester", "level");



ALTER TABLE ONLY "public"."course_catalogs"
    ADD CONSTRAINT "course_catalogs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."credit_transactions"
    ADD CONSTRAINT "credit_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."credits"
    ADD CONSTRAINT "credits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_user_id_fcm_token_key" UNIQUE ("user_id", "fcm_token");



ALTER TABLE ONLY "public"."gpa_data"
    ADD CONSTRAINT "gpa_data_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."news_images"
    ADD CONSTRAINT "news_images_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."password_reset_attempts"
    ADD CONSTRAINT "password_reset_attempts_pkey" PRIMARY KEY ("email");



ALTER TABLE ONLY "public"."post_unlocks"
    ADD CONSTRAINT "post_unlocks_pkey" PRIMARY KEY ("user_id", "post_id");



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reactions"
    ADD CONSTRAINT "reactions_pkey" PRIMARY KEY ("post_id", "user_id");



CREATE INDEX "comment_reports_comment_id_idx" ON "public"."comment_reports" USING "btree" ("comment_id");



CREATE INDEX "comment_reports_pending_idx" ON "public"."comment_reports" USING "btree" ("comment_id") WHERE ("resolved_at" IS NULL);



CREATE INDEX "comments_parent_id_idx" ON "public"."comments" USING "btree" ("parent_id") WHERE ("parent_id" IS NOT NULL);



CREATE INDEX "comments_post_id_idx" ON "public"."comments" USING "btree" ("post_id");



CREATE UNIQUE INDEX "credit_transactions_grant_reference_id_unique" ON "public"."credit_transactions" USING "btree" ("reference_id") WHERE (("reference_id" IS NOT NULL) AND ("reason" = ANY (ARRAY['admin_topup'::"text", 'admin_bonus'::"text", 'signup_bonus'::"text"])));



CREATE INDEX "idx_credit_tx_reason_label_trgm" ON "public"."credit_transactions" USING "gin" ("reason_label" "public"."gin_trgm_ops");



CREATE INDEX "idx_credit_tx_user_created" ON "public"."credit_transactions" USING "btree" ("user_id", "created_at" DESC, "id" DESC);



CREATE INDEX "idx_credit_tx_user_delta" ON "public"."credit_transactions" USING "btree" ("user_id", "delta");



CREATE UNIQUE INDEX "notifications_announcement_post_user_uniq" ON "public"."notifications" USING "btree" ("post_id", "user_id") WHERE ("type" = 'announcement'::"text");



CREATE UNIQUE INDEX "notifications_daily_tip_post_user_uniq" ON "public"."notifications" USING "btree" ("post_id", "user_id") WHERE ("type" = 'daily_tip'::"text");



CREATE UNIQUE INDEX "notifications_reply_comment_uniq" ON "public"."notifications" USING "btree" ("comment_id") WHERE ("type" = 'reply'::"text");



CREATE INDEX "notifications_user_created_idx" ON "public"."notifications" USING "btree" ("user_id", "created_at" DESC);



CREATE OR REPLACE TRIGGER "notifications_push_trigger" AFTER INSERT ON "public"."notifications" FOR EACH ROW EXECUTE FUNCTION "public"."notify_push"();



CREATE OR REPLACE TRIGGER "trg_touch_course_catalogs" BEFORE UPDATE ON "public"."course_catalogs" FOR EACH ROW EXECUTE FUNCTION "public"."touch_course_catalogs_updated_at"();



CREATE OR REPLACE TRIGGER "update_gpa_data_updated_at" BEFORE UPDATE ON "public"."gpa_data" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



ALTER TABLE ONLY "public"."bookmarks"
    ADD CONSTRAINT "bookmarks_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bookmarks"
    ADD CONSTRAINT "bookmarks_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_reports"
    ADD CONSTRAINT "comment_reports_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_reports"
    ADD CONSTRAINT "comment_reports_reporter_id_fkey" FOREIGN KEY ("reporter_id") REFERENCES "public"."gpa_data"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_votes"
    ADD CONSTRAINT "comment_votes_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comment_votes"
    ADD CONSTRAINT "comment_votes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."comments"
    ADD CONSTRAINT "comments_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."credit_transactions"
    ADD CONSTRAINT "credit_transactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."credits"
    ADD CONSTRAINT "credits_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."device_tokens"
    ADD CONSTRAINT "device_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gpa_data"
    ADD CONSTRAINT "gpa_data_avatar_id_fkey" FOREIGN KEY ("avatar_id") REFERENCES "public"."avatars"("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "public"."comments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."post_unlocks"
    ADD CONSTRAINT "post_unlocks_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."post_unlocks"
    ADD CONSTRAINT "post_unlocks_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."posts"
    ADD CONSTRAINT "posts_author_id_fkey" FOREIGN KEY ("author_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reactions"
    ADD CONSTRAINT "reactions_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "public"."posts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reactions"
    ADD CONSTRAINT "reactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "Authenticated users can insert comments" ON "public"."comments" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "author_id"));



CREATE POLICY "Authenticated users can read course catalogs" ON "public"."course_catalogs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authors and admins can delete posts" ON "public"."posts" FOR DELETE USING ((("auth"."uid"() = "author_id") OR (EXISTS ( SELECT 1
   FROM "public"."gpa_data"
  WHERE (("gpa_data"."id" = "auth"."uid"()) AND ("gpa_data"."role" = 'admin'::"text"))))));



CREATE POLICY "Authors can update own posts" ON "public"."posts" FOR UPDATE USING (("auth"."uid"() = "author_id"));



CREATE POLICY "Avatars are publicly readable" ON "public"."avatars" FOR SELECT USING (true);



CREATE POLICY "Comment votes are publicly readable" ON "public"."comment_votes" FOR SELECT USING (true);



CREATE POLICY "Comments are publicly readable" ON "public"."comments" FOR SELECT USING (true);



CREATE POLICY "Comments viewable by all" ON "public"."comments" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "News images are publicly readable" ON "public"."news_images" FOR SELECT USING (true);



CREATE POLICY "Only contributors can insert posts" ON "public"."posts" FOR INSERT WITH CHECK ((("auth"."uid"() = "author_id") AND (EXISTS ( SELECT 1
   FROM "public"."gpa_data"
  WHERE (("gpa_data"."id" = "auth"."uid"()) AND ("gpa_data"."role" = ANY (ARRAY['contributor'::"text", 'admin'::"text"]))))) AND (("post_type" = 'news'::"text") OR (("post_type" = ANY (ARRAY['announcement'::"text", 'daily_tip'::"text"])) AND (EXISTS ( SELECT 1
   FROM "public"."gpa_data"
  WHERE (("gpa_data"."id" = "auth"."uid"()) AND ("gpa_data"."role" = 'admin'::"text"))))))));



CREATE POLICY "Posts are publicly readable" ON "public"."posts" FOR SELECT USING (true);



CREATE POLICY "Public profiles are viewable by all" ON "public"."gpa_data" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Reactions are publicly readable" ON "public"."reactions" FOR SELECT USING (true);



CREATE POLICY "Users can insert own data" ON "public"."gpa_data" FOR INSERT WITH CHECK (("auth"."uid"() = "id"));



CREATE POLICY "Users can update own data" ON "public"."gpa_data" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can view own credits" ON "public"."credits" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Users can view own data" ON "public"."gpa_data" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Users manage own bookmarks" ON "public"."bookmarks" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own comment votes" ON "public"."comment_votes" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own reaction" ON "public"."reactions" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users view own unlocks" ON "public"."post_unlocks" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."avatars" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bookmarks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comment_reports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comment_votes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."course_catalogs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."credit_transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."credits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."device_tokens" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "device_tokens_own" ON "public"."device_tokens" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."gpa_data" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."news_images" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notifications_select_own" ON "public"."notifications" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "notifications_update_own" ON "public"."notifications" FOR UPDATE USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."password_reset_attempts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."post_unlocks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."posts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."reactions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "select_own_transactions" ON "public"."credit_transactions" FOR SELECT USING (("user_id" = "auth"."uid"()));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."credit_transactions";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."admin_delete_comment"("p_comment_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_delete_comment"("p_comment_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_comment"("p_comment_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."broadcast_announcement"("p_post_id" "uuid", "p_title" "text", "p_body" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."broadcast_announcement"("p_post_id" "uuid", "p_title" "text", "p_body" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."broadcast_announcement"("p_post_id" "uuid", "p_title" "text", "p_body" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."broadcast_announcement"("p_post_id" "uuid", "p_title" "text", "p_body" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."broadcast_daily_tip"("p_post_id" "uuid", "p_title" "text", "p_body" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."broadcast_daily_tip"("p_post_id" "uuid", "p_title" "text", "p_body" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."broadcast_daily_tip"("p_post_id" "uuid", "p_title" "text", "p_body" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."broadcast_daily_tip"("p_post_id" "uuid", "p_title" "text", "p_body" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."check_and_log_reset_attempt"("p_email" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."check_and_log_reset_attempt"("p_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."check_and_log_reset_attempt"("p_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_and_log_reset_attempt"("p_email" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."clear_all_notifications"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."clear_all_notifications"() TO "anon";
GRANT ALL ON FUNCTION "public"."clear_all_notifications"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clear_all_notifications"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_comment"("p_comment_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_comment"("p_comment_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_comment"("p_comment_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_comment"("p_comment_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."dismiss_comment_reports"("p_comment_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dismiss_comment_reports"("p_comment_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."dismiss_comment_reports"("p_comment_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."dismiss_comment_reports"("p_comment_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."comments" TO "anon";
GRANT ALL ON TABLE "public"."comments" TO "authenticated";
GRANT ALL ON TABLE "public"."comments" TO "service_role";



REVOKE ALL ON FUNCTION "public"."edit_comment"("p_comment_id" "uuid", "p_body" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."edit_comment"("p_comment_id" "uuid", "p_body" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."edit_comment"("p_comment_id" "uuid", "p_body" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."edit_comment"("p_comment_id" "uuid", "p_body" "text") TO "service_role";



GRANT ALL ON TABLE "public"."credit_transactions" TO "anon";
GRANT ALL ON TABLE "public"."credit_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."credit_transactions" TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_credit_history"("p_limit" integer, "p_before_created_at" timestamp with time zone, "p_before_id" "uuid", "p_direction" "text", "p_since" timestamp with time zone, "p_search" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_credit_history"("p_limit" integer, "p_before_created_at" timestamp with time zone, "p_before_id" "uuid", "p_direction" "text", "p_since" timestamp with time zone, "p_search" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_credit_history"("p_limit" integer, "p_before_created_at" timestamp with time zone, "p_before_id" "uuid", "p_direction" "text", "p_since" timestamp with time zone, "p_search" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_credit_history"("p_limit" integer, "p_before_created_at" timestamp with time zone, "p_before_id" "uuid", "p_direction" "text", "p_since" timestamp with time zone, "p_search" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "service_role";



REVOKE ALL ON FUNCTION "public"."grant_credits"("p_user_id" "uuid", "p_amount" integer, "p_reason" "text", "p_reference_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."grant_credits"("p_user_id" "uuid", "p_amount" integer, "p_reason" "text", "p_reference_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user_credits"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user_credits"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user_credits"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."mark_all_notifications_read"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_all_notifications_read"() TO "anon";
GRANT ALL ON FUNCTION "public"."mark_all_notifications_read"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."mark_all_notifications_read"() TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_push"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_push"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_push"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."notify_reply"("p_comment_id" "uuid", "p_parent_id" "uuid", "p_post_id" "uuid", "p_body" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notify_reply"("p_comment_id" "uuid", "p_parent_id" "uuid", "p_post_id" "uuid", "p_body" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."notify_reply"("p_comment_id" "uuid", "p_parent_id" "uuid", "p_post_id" "uuid", "p_body" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_reply"("p_comment_id" "uuid", "p_parent_id" "uuid", "p_post_id" "uuid", "p_body" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text", "p_parent_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text", "p_parent_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."post_comment"("p_post_id" "uuid", "p_body" "text", "p_parent_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."report_comment"("p_comment_id" "uuid", "p_reason" "text", "p_other_text" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."report_comment"("p_comment_id" "uuid", "p_reason" "text", "p_other_text" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."report_comment"("p_comment_id" "uuid", "p_reason" "text", "p_other_text" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."report_comment"("p_comment_id" "uuid", "p_reason" "text", "p_other_text" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "postgres";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "anon";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "service_role";



GRANT ALL ON FUNCTION "public"."show_limit"() TO "postgres";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "anon";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."spend_credits"("p_cost" integer, "p_reason" "text", "p_reference_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."spend_credits"("p_cost" integer, "p_reason" "text", "p_reference_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."spend_credits"("p_cost" integer, "p_reason" "text", "p_reference_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."spend_credits"("p_cost" integer, "p_reason" "text", "p_reference_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_course_catalogs_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_course_catalogs_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_course_catalogs_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."unlock_post"("p_post_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."unlock_post"("p_post_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."unlock_post"("p_post_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."vote_comment"("p_comment_id" "uuid", "p_vote" smallint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."vote_comment"("p_comment_id" "uuid", "p_vote" smallint) TO "anon";
GRANT ALL ON FUNCTION "public"."vote_comment"("p_comment_id" "uuid", "p_vote" smallint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."vote_comment"("p_comment_id" "uuid", "p_vote" smallint) TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "service_role";


















GRANT ALL ON TABLE "public"."avatars" TO "anon";
GRANT ALL ON TABLE "public"."avatars" TO "authenticated";
GRANT ALL ON TABLE "public"."avatars" TO "service_role";



GRANT ALL ON TABLE "public"."bookmarks" TO "anon";
GRANT ALL ON TABLE "public"."bookmarks" TO "authenticated";
GRANT ALL ON TABLE "public"."bookmarks" TO "service_role";



GRANT ALL ON TABLE "public"."comment_reports" TO "anon";
GRANT ALL ON TABLE "public"."comment_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."comment_reports" TO "service_role";



GRANT ALL ON TABLE "public"."comment_votes" TO "anon";
GRANT ALL ON TABLE "public"."comment_votes" TO "authenticated";
GRANT ALL ON TABLE "public"."comment_votes" TO "service_role";



GRANT ALL ON TABLE "public"."course_catalogs" TO "anon";
GRANT ALL ON TABLE "public"."course_catalogs" TO "authenticated";
GRANT ALL ON TABLE "public"."course_catalogs" TO "service_role";



GRANT ALL ON SEQUENCE "public"."course_catalogs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."course_catalogs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."course_catalogs_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."credits" TO "anon";
GRANT ALL ON TABLE "public"."credits" TO "authenticated";
GRANT ALL ON TABLE "public"."credits" TO "service_role";



GRANT ALL ON TABLE "public"."device_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."device_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."gpa_data" TO "anon";
GRANT ALL ON TABLE "public"."gpa_data" TO "authenticated";
GRANT ALL ON TABLE "public"."gpa_data" TO "service_role";



GRANT ALL ON TABLE "public"."news_images" TO "anon";
GRANT ALL ON TABLE "public"."news_images" TO "authenticated";
GRANT ALL ON TABLE "public"."news_images" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "service_role";
GRANT SELECT,UPDATE ON TABLE "public"."notifications" TO "authenticated";



GRANT ALL ON TABLE "public"."password_reset_attempts" TO "anon";
GRANT ALL ON TABLE "public"."password_reset_attempts" TO "authenticated";
GRANT ALL ON TABLE "public"."password_reset_attempts" TO "service_role";



GRANT ALL ON TABLE "public"."post_unlocks" TO "anon";
GRANT ALL ON TABLE "public"."post_unlocks" TO "authenticated";
GRANT ALL ON TABLE "public"."post_unlocks" TO "service_role";



GRANT ALL ON TABLE "public"."posts" TO "anon";
GRANT ALL ON TABLE "public"."posts" TO "authenticated";
GRANT ALL ON TABLE "public"."posts" TO "service_role";



GRANT ALL ON TABLE "public"."reactions" TO "anon";
GRANT ALL ON TABLE "public"."reactions" TO "authenticated";
GRANT ALL ON TABLE "public"."reactions" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";



































