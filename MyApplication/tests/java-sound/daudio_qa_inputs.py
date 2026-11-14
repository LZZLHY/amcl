"""标准 java-sound-17 的 DAUDIO 输入闭包校验，不能接受任意 QA 命令或提高其它 suite 能力。"""
import hashlib
import json
from pathlib import Path
import re


PATCH_PATHS = {
    'make/modules/java.desktop/Lib.gmk',
    'src/java.desktop/share/native/libjsound/DirectAudioDevice.c',
    'src/java.desktop/share/native/libjsound/ohos_daudio.h',
    'src/java.desktop/linux/native/libjsound/ohos_daudio.c',
    *('src/java.desktop/share/classes/com/sun/media/sound/' + name for name in
      ('AbstractLine.java', 'AbstractDataLine.java', 'AbstractMixer.java', 'DirectAudioDevice.java')),
}
REQUIRED = {'candidate.patch', 'baseline-0011.patch', 'backend/ohos_daudio.c', 'backend/ohos_daudio.h',
            'tests/daudio_backend_test.c', 'tests/daudio_jni_control.c', 'tests/DaudioJniRegression.java',
            'tests/SoundLifecycleRegression.java', 'sdk/ohaudio/native_audiostreambuilder.h',
            'sdk/ohaudio/native_audiorenderer.h', 'sdk/ohaudio/native_audio_routing_manager.h',
            'sdk/info/application_target_sdk_version.h', 'sdk/multimedia/native_audio_channel_layout.h'}
CAPTURE_REQUIRED = REQUIRED | {'baseline-0023.patch', 'backend/ohos_capture_ring.h', 'backend/ohos_daudio_callbacks.h',
    'tests/DaudioCaptureJniRegression.java', 'tests/daudio_capture_jni_control.c', 'sdk/ohaudio/native_audiocapturer.h'}
CAPTURE_PATCH_PATHS = {'src/java.desktop/share/native/libjsound/DirectAudioDevice.c',
    'src/java.desktop/linux/native/libjsound/ohos_daudio.c',
    'src/java.desktop/share/native/libjsound/ohos_capture_ring.h',
    'src/java.desktop/share/native/libjsound/ohos_daudio_callbacks.h'}
TIMELINE_REQUIRED = CAPTURE_REQUIRED | {'baseline-0025.patch', 'backend/ohos_playback_timeline.h',
    'tests/DaudioTimelineJniRegression.java'}
TIMELINE_PATCH_PATHS = (CAPTURE_PATCH_PATHS - {'src/java.desktop/share/native/libjsound/ohos_capture_ring.h'}) | {
    'src/java.desktop/share/native/libjsound/ohos_daudio.h', 'src/java.desktop/share/native/libjsound/ohos_playback_timeline.h'}


def validate(manifest, expected_sha, expected_commit):
    """先核独立 manifest SHA，再逐文件核路径/长度/摘要，额外文件和链接同样拒绝。"""
    path = Path(manifest)
    if not path.is_absolute() or path.is_symlink() or path.name != 'manifest.json':
        raise ValueError('DAUDIO requires an absolute ordinary manifest.json')
    if not re.fullmatch('[0-9a-f]{64}', expected_sha or ''):
        raise ValueError('DAUDIO requires independent lowercase manifest SHA256')
    data = path.read_bytes()
    if len(data) > 256 * 1024 or hashlib.sha256(data).hexdigest() != expected_sha:
        raise ValueError('DAUDIO manifest identity differs')
    facts = json.loads(data)
    if facts.get('schema') not in ('amcl-daudio-jni-inputs/v1', 'amcl-daudio-jni-inputs/v2', 'amcl-daudio-jni-inputs/v3') or facts.get('major') != 17 or facts.get('sourceCommit') != expected_commit:
        raise ValueError('DAUDIO schema/major/locked source commit mismatch')
    timeline = facts['schema'] == 'amcl-daudio-jni-inputs/v3'
    duplex = facts['schema'] != 'amcl-daudio-jni-inputs/v1'
    required = TIMELINE_REQUIRED if timeline else CAPTURE_REQUIRED if duplex else REQUIRED
    files = facts.get('files')
    if not isinstance(files, list) or not 13 <= len(files) <= 160:
        raise ValueError('DAUDIO file inventory is invalid')
    root = path.parent.resolve(); names = set(); total = 0
    for entry in files:
        name = entry.get('path')
        if not isinstance(name, str) or '\\' in name or name.startswith('/') or '..' in Path(name).parts or name in names:
            raise ValueError('DAUDIO duplicate/unsafe input path')
        if name not in required and not re.fullmatch(r'sdk/(?:ohaudio|info)/[a-zA-Z0-9_]+\.h', name):
            raise ValueError('DAUDIO unexpected input path: ' + name)
        candidate = root / name
        if candidate.is_symlink() or not candidate.is_file() or not candidate.resolve().is_relative_to(root):
            raise ValueError('DAUDIO non-ordinary/escaping input')
        content = candidate.read_bytes()
        if len(content) > 2 * 1024 * 1024 or type(entry.get('bytes')) is not int or len(content) != entry['bytes'] or \
            hashlib.sha256(content).hexdigest() != entry.get('sha256'):
            raise ValueError('DAUDIO file bytes changed: ' + name)
        names.add(name); total += len(content)
    if total > 8 * 1024 * 1024 or not required <= names:
        raise ValueError('DAUDIO incomplete or oversized input closure')
    actual = set()
    for p in root.rglob('*'):
        if p.is_symlink(): raise ValueError('DAUDIO input closure contains a link')
        if p.is_file(): actual.add(p.relative_to(root).as_posix())
    if actual != names | {'manifest.json'}:
        raise ValueError('DAUDIO input closure contains unlisted files')
    modified = set(re.findall(r'^\+\+\+ b/(.+)$', (root / 'candidate.patch').read_text(encoding='utf-8'), re.M))
    if modified != (TIMELINE_PATCH_PATHS if timeline else CAPTURE_PATCH_PATHS if duplex else PATCH_PATHS):
        raise ValueError('DAUDIO patch crosses fixed JavaSound boundary')
    if duplex:
        baseline = set(re.findall(r'^\+\+\+ b/(.+)$', (root / 'baseline-0023.patch').read_text(encoding='utf-8'), re.M))
        if baseline != PATCH_PATHS: raise ValueError('DAUDIO0023 baseline crosses original fixed boundary')
    if timeline:
        baseline = set(re.findall(r'^\+\+\+ b/(.+)$', (root / 'baseline-0025.patch').read_text(encoding='utf-8'), re.M))
        if baseline != CAPTURE_PATCH_PATHS: raise ValueError('DAUDIO0025 baseline crosses fixed Capture boundary')
    return {'manifest': str(path.resolve()), 'root': str(root), 'manifestSha256': expected_sha,
            'sourceCommit': expected_commit, 'files': len(names), 'bytes': total,
            'scope': 'host Java/JNI/OHAudio-protocol only; target qualification remains separate'}
