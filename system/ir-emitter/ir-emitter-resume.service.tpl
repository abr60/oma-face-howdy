[Unit]
Description=Re-enable IR Emitter after resume
After=suspend.target hibernate.target hybrid-sleep.target

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=CHANGEME_LEIRE_BIN run

[Install]
WantedBy=suspend.target hibernate.target hybrid-sleep.target
