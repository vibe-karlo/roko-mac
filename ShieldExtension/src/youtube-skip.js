// An ad that plays all the same goes by muted and fast, and the video comes
// back as it was. The same as roko's YouTubeAds.skipper; kept in step by hand.
(function () {
  'use strict';
  if (["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"].indexOf(location.hostname) < 0) return;
  var held = new WeakMap();
  function look(event) {
    var video = event.target;
    if (!(video instanceof HTMLVideoElement)) return;
    var player = video.closest('.html5-video-player');
    var ad = !!player && player.classList.contains('ad-showing');
    var was = held.get(video);
    try {
      if (ad) {
        if (!was) {
          was = { muted: video.muted, rate: video.playbackRate };
          held.set(video, was);
          video.muted = true;
        }
        if (video.playbackRate !== 16) video.playbackRate = 16;
      } else if (was) {
        held.delete(video);
        video.playbackRate = was.rate;
        video.muted = was.muted;
      }
    } catch (e) {}
  }
  ['playing', 'timeupdate', 'durationchange', 'emptied'].forEach(function (type) {
    document.addEventListener(type, look, true);
  });
})();
