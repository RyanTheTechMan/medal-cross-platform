#!/usr/bin/env python3
"""Generate synthetic test media and remux two closed-GOP segments. No screen capture."""
import json, subprocess
from pathlib import Path
root=Path(__file__).resolve().parent/'media';root.mkdir(exist_ok=True)
def run(*args): return subprocess.run(args,check=True,capture_output=True,text=True)
run('ffmpeg','-hide_banner','-loglevel','error','-y','-f','lavfi','-i','testsrc2=size=640x360:rate=30','-f','lavfi','-i','sine=frequency=440:sample_rate=48000','-t','8','-c:v','libx264','-preset','veryfast','-pix_fmt','yuv420p','-g','60','-keyint_min','60','-sc_threshold','0','-bf','0','-c:a','aac','-f','segment','-segment_time','2','-reset_timestamps','1',str(root/'part-%02d.mp4'))
(root/'replay.txt').write_text("file 'part-02.mp4'\nfile 'part-03.mp4'\n")
run('ffmpeg','-hide_banner','-loglevel','error','-y','-f','concat','-safe','1','-i',str(root/'replay.txt'),'-c','copy','-movflags','+faststart',str(root/'replay.mp4'))
result=json.loads(run('ffprobe','-v','error','-show_format','-show_streams','-of','json',str(root/'replay.mp4')).stdout)
assert 3.8<float(result['format']['duration'])<4.3, result['format']
assert {'h264','aac'} <= {s['codec_name'] for s in result['streams']}
(root.parent/'media_result.json').write_text(json.dumps(result,indent=2))
print('PASS: synthetic H.264/AAC replay file; no native or GPU capture exercised')
