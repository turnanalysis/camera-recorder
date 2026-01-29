# Check status
sudo systemctl status camera-recorder.service
sudo systemctl status flying-yankee-stream.service

# Restart if needed
sudo systemctl restart camera-recorder.service

# View recording status
./record_cameras.sh status
