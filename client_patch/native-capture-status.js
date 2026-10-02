/* Native capture truth for the original header when no game category exists.
 * This is control state only; it never classifies an application as a game. */
(function installNativeCaptureStatus() {
  if (window.NativeMedalCaptureStatus) return;
  const label = value => value?.schemaVersion === 1 && value.state === 'capturing' &&
    typeof value.applicationName === 'string' && value.applicationName.trim()
      ? value.applicationName.trim().slice(0, 160) : null;
  window.NativeMedalCaptureStatus = Object.freeze({
    label,
    useApplicationName(React) {
      const [name, setName] = React.useState(null);
      React.useEffect(() => {
        if (!['darwin', 'linux'].includes(window.MedalEnv?.platform)) return;
        let disposed = false, timer;
        const refresh = async () => {
          let next = null;
          try { next = label(await window.MedalIPC.sendRecorderWSRequest('nativePort.captureActivity', {})); } catch {}
          if (disposed) return;
          setName(next);
          timer = setTimeout(refresh, 800);
        };
        refresh();
        return () => {disposed = true; clearTimeout(timer);};
      }, []);
      return name;
    },
  });
})();
