# Quickshell Lock for SDDM

This SDDM theme mirrors `QuickLock.qml`: the current theme image or video fills
the screen, while the clock, date, animated password trace, colours, and sizing
match the Quickshell lock screen. Videos play directly and silently in a loop;
image themes render their real image instead.

The production copy is installed as `/usr/share/sddm/themes/quickshell-lock`.
`../scripts/sync_sddm_theme.sh` updates its selected media and colour
configuration after every Quickshell theme change.

Test the source copy without changing the active display manager:

```sh
sddm-greeter-qt6 --test-mode --theme "$HOME/.config/quickshell/atelier/sddm-theme"
```
