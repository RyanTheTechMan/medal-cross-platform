/* Project-owned transaction, called by the original Save / Save Copy routes.
 * Dependencies are the imported client's public persistence/cache operations. */
function createNativeAudioEditor({ ipc, onCommitted, trimMetadata, rebaseBookmarks, gameName }) {
  const pending = new Set();
  const read = async id => {
    const row = (await ipc.getContents({ localContentId: id, limit: 1, skipRegeneration: true })).contents?.[0];
    if (!row || row.local_content_id !== id) throw new Error('The local clip could not be read');
    return row;
  };
  const same = (row, change) => row.video_path === change.video_path &&
    JSON.stringify(row.metadata?.audioStreams) === JSON.stringify(change.metadata.audioStreams);
  async function perform(clip, request, copy) {
    const id = clip.getUUID();
    if (pending.has(id)) throw new Error('This clip already has an edit in progress');
    pending.add(id);
    try {
      const original = await read(id);
      const preview = typeof window !== 'undefined' ? window.NativeMedalAudioPreviewController : null;
      const checkpoint = preview?.editCheckpoint(id);
      const start = copy ? request.startTime : request.trimStartTimeInSeconds;
      const duration = copy ? request.duration : request.trimDurationInSeconds;
      const mask = new Map((request.audioStreams || []).map(s => [s.index, s.isMuted === true]));
      const selection = (original.metadata.audioStreams || []).map(s => ({ ...s,
        isMuted: mask.has(s.index) ? mask.get(s.index) : s.isMuted === true }));
      const output = await ipc.trimVideo({ nativeContentId: id, videoPath: original.video_path,
        startTime: start, duration, audioStreams: selection, deleteOriginal: false });
      if (!output.nativeAudioEdit || !output.outputPath || output.outputPath === original.video_path ||
          !Array.isArray(output.audioStreams)) throw new Error('Native edit did not return a new validated file');
      if (!same(await read(id), original)) throw new Error('The clip changed while editing; the source was retained');
      const metadata = { ...original.metadata, ...trimMetadata({ trimStart: start, trimDuration: duration,
        parentTrimStartTime: original.metadata?.trimStartTime, sourceVideoDuration: clip.getDuration() }),
        audioStreams: output.audioStreams, contentSize: output.contentSize, contentInode: output.contentInode,
        clipDuration: output.actualDuration, bookmarks: rebaseBookmarks(original.metadata.bookmarks, start, duration),
        thumbnailInode: null, thumbnailSize: null };
      const change = { video_path: output.outputPath, thumbnail_path: null, film_reel_path: null, metadata };
      let committed;
      if (copy) {
        for (const key of ['clipType', 'uploadedAt', 'migratedAt', 'remoteContent', 'remoteSyncedAt',
          'userTags', 'playerTags', 'tags', 'collections']) delete metadata[key];
        metadata.recorder = { ...metadata.recorder, clipType: undefined, triggerType: undefined };
        const { count } = await ipc.getContents({ parentId: id, count: true, limit: 0 });
        metadata.title = `${gameName(original.category_id) || original.metadata.recorder?.captionName || 'Unknown Game'} Trimmed Clip ${(count || 0) + 1}`;
        const row = { ...change, local_content_id: crypto.randomUUID(), parent_id: id,
          category_id: original.category_id, created_at: Math.floor(Date.now() / 1000) };
        await ipc.insertContentRaw(row);
        committed = await read(row.local_content_id);
        if (!same(committed, change)) throw new Error('Save Copy could not be verified; original and output were retained');
      } else {
        const updated = await ipc.updateContent({ local_content_id: id }, change);
        if (!updated?.changes) throw new Error('The library rejected the edit; the original was retained');
        try {
          committed = await read(id);
          if (!same(committed, change)) throw new Error('The saved edit could not be verified');
        } catch (error) {
          // Keep both media files regardless of rollback success. No swallowed DB errors.
          try {
            await ipc.updateContent({ local_content_id: id }, { video_path: original.video_path,
              metadata: original.metadata, thumbnail_path: original.thumbnail_path, film_reel_path: original.film_reel_path });
          } catch { throw new Error(`${error.message}; rollback failed. Both media files were retained.`); }
          throw error;
        }
      }
      // Regenerate derived assets only after path + manifest were read back. Never
      // remove shared originals: other library rows and undo may still use them.
      const refreshed = (await ipc.getContents({ localContentId: committed.local_content_id,
        limit: 1, skipRegeneration: false })).contents?.[0];
      if (!refreshed || !same(refreshed, change)) throw new Error('The saved clip could not be reloaded; media was retained');
      if (!copy) { clip.content = refreshed; clip.currentAudioStreams = refreshed.metadata.audioStreams; }
      if (!copy && checkpoint) preview.expectSaved({ ...checkpoint, uuid: id, path: refreshed.video_path,
        time: Math.max(0, checkpoint.time - (start || 0)) });
      onCommitted(refreshed);
      return refreshed;
    } finally { pending.delete(id); }
  }
  return {
    async edit(clip, request, callback) {
      try {
        const row = await perform(clip, request, false);
        callback?.(null, row.video_path, row.thumbnail_path);
        return row;
      } catch (error) { if (callback) callback(error); else throw error; }
    },
    copy: (clip, request) => perform(clip, request, true),
  };
}
if (typeof module !== 'undefined') module.exports = { createNativeAudioEditor };
