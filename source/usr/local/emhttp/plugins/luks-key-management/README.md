A plugin to securely auto-start LUKS-encrypted arrays and pools during boot.
It adds an additional, hardware-bound unlock key generated from your router’s MAC address and motherboard ID.
The key is never stored or downloaded—it’s recalculated on each boot.
Your original passphrase remains unchanged and can still be used for manual unlock.