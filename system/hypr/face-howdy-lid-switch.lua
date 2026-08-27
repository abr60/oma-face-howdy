-- face.howdy: lid-open face unlock via Howdy.
-- Appended to the user's Hyprland bindings by the face.howdy deploy step and
-- removed by the restore step. Guarded by the markers below so it is idempotent.
o.bind("switch:on:Lid Switch", "Howdy Lid Open", "omarchy-shell lock howdyRetry")
o.bind("switch:off:Lid Switch", "Howdy Lid Close", "omarchy-shell lock howdyRetry")
