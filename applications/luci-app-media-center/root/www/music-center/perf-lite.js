/* ============================================================================
   音乐中心 · 低性能设备模式
   在 CSS 解析前执行：iPhone / iPod 默认启用精简动效，避免 iOS 上模糊层、
   backdrop-filter 和逐帧重绘导致卡顿。可用 ?perf=full 临时关闭，
   或用 ?perf=lite 在 iPad / 电脑上强制预览精简模式。
   ========================================================================== */
(function () {
    'use strict';
    try {
        var ua = navigator.userAgent || '';
        var m = /[?&]perf=(lite|full)(?:&|#|$)/.exec(window.location.search || '');
        var smallTouch = false;
        try {
            var sw = Number(screen.width) || 0;
            var sh = Number(screen.height) || 0;
            var shortSide = Math.min(sw || 9999, sh || 9999);
            smallTouch = navigator.maxTouchPoints > 1 && shortSide > 0 && shortSide <= 500;
        } catch (e2) { /* ignore */ }
        var lite = m ? m[1] === 'lite' : (/iPhone|iPod/i.test(ua) || smallTouch);
        if (lite) document.documentElement.classList.add('perf-lite');
    } catch (e) { /* 忽略：禁用 JS 时保持完整效果 */ }
})();
