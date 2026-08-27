[Unit]
Description=Enable IR Emitter for Howdy

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=CHANGEME_LEIRE_BIN run
