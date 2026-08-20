import subprocess, time
from db import list_uploads_since, mark_encoded

def nightly_reencode():
    started = time.time()
    for upload in list_uploads_since(hours=24):
        if upload.encoded:
            continue
        rc = subprocess.call([
            "ffmpeg", "-y", "-i", upload.src_path,
            "-c:v", "libx264", "-preset", "medium", upload.out_path,
        ])
        if rc == 0:
            mark_encoded(upload.id)
        else:
            print("encode failed", upload.id, rc)
    print("done in", time.time() - started, "s")
