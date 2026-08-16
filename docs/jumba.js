/* ============================================================================
 * jumba.js — the live dog in the hero panel.
 *
 * A small browser re-implementation of what DogBrain/PetScene do in the app:
 * weighted autonomy, eight facing directions off the velocity vector, window
 * title bars as walkable surfaces, gravity when he's shaken off one.
 *
 * It is deliberately NOT a port. The app is the source of truth; this exists so
 * the download page can show the thing instead of describing it. No storage, no
 * network, no dependencies.
 * ========================================================================= */

window.__initJumba = function () {
  'use strict';

  var canvas = document.getElementById('jumba-canvas');
  if (!canvas || !canvas.getContext) return;
  var ctx = canvas.getContext('2d');

  /* ── version label ─────────────────────────────────────────────────────
     Single source of truth: <body data-version="v4.0">. */
  var version = document.body.getAttribute('data-version') || '';
  if (version) {
    Array.prototype.forEach.call(
      document.querySelectorAll('[data-version-label]'),
      function (el) { el.textContent = version + ' · Jumbini.dmg'; }
    );
  }

  /* ── menu bar clock, because a fake one that's wrong is worse ─────────── */
  var clockEl = document.querySelector('[data-clock]');
  function tickClock() {
    if (!clockEl) return;
    var d = new Date();
    var h = d.getHours(), m = d.getMinutes();
    var ampm = h >= 12 ? 'PM' : 'AM';
    h = h % 12; if (h === 0) h = 12;
    clockEl.textContent = h + ':' + (m < 10 ? '0' : '') + m + ' ' + ampm;
  }
  tickClock();
  setInterval(tickClock, 20000);

  /* ── sprites ───────────────────────────────────────────────────────────── */

  var DIRS = ['south', 'south-east', 'east', 'north-east',
              'north', 'north-west', 'west', 'south-west'];
  var STATES = ['idle', 'run1', 'run2', 'sit', 'sleep', 'sniff',
                'bark', 'peek', 'stalk', 'pounce'];

  var sprites = {};          // "idle_east" -> {img, box}
  var props = {};            // "heart"     -> {img, box}
  var pending = 0;
  var ready = false;

  function load(store, key, url) {
    var img = new Image();
    var rec = { img: img, box: null };
    store[key] = rec;
    pending++;
    img.onload = function () {
      rec.box = measure(img);
      if (--pending === 0) ready = true;
    };
    img.onerror = function () { if (--pending === 0) ready = true; };
    img.src = (window.__INLINE_ASSETS && window.__INLINE_ASSETS[url]) || url;
  }

  /* Content bounding box, so a 48x48 sprite and the 68x76 sit sprite both
     stand on the same floor line instead of floating by their padding. */
  function measure(img) {
    var w = img.naturalWidth, h = img.naturalHeight;
    var fallback = { x0: 0, y0: 0, w: w, h: h };
    try {
      var c = document.createElement('canvas');
      c.width = w; c.height = h;
      var cc = c.getContext('2d', { willReadFrequently: true });
      cc.drawImage(img, 0, 0);
      var d = cc.getImageData(0, 0, w, h).data;
      var minX = w, minY = h, maxX = -1, maxY = -1;
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (d[(y * w + x) * 4 + 3] > 8) {
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
            if (y < minY) minY = y;
            if (y > maxY) maxY = y;
          }
        }
      }
      if (maxX < 0) return fallback;
      return { x0: minX, y0: minY, w: maxX + 1 - minX, h: maxY + 1 - minY };
    } catch (e) {
      return fallback;   // canvas tainted (file:// preview) — anchor naively
    }
  }

  STATES.forEach(function (s) {
    DIRS.forEach(function (d) {
      load(sprites, s + '_' + d, 'assets/jumba/' + s + '_' + d + '.png');
    });
  });
  ['heart', 'shadow_blob', 'bark_puff_0', 'bark_puff_1', 'bark_puff_2',
   'dust_0', 'dust_1', 'dust_2', 'dust_3'].forEach(function (p) {
    load(props, p, 'assets/props/' + p + '.png');
  });

  /* ── geometry ──────────────────────────────────────────────────────────── */

  var W = 0, H = 0, dpr = 1;
  var SCALE = 2.2;          // sprite pixel scale, recomputed on resize
  var GROUND = 0;
  var windows = [];
  var TITLEBAR = 22;        // px of window chrome he stands on

  function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
  function rand(a, b) { return a + Math.random() * (b - a); }

  function layout() {
    var rect = canvas.getBoundingClientRect();
    W = Math.max(1, Math.round(rect.width));
    H = Math.max(1, Math.round(rect.height));
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.imageSmoothingEnabled = false;

    SCALE = Math.max(1.25, Math.min(2.2, (H / 420) * 2.2));
    GROUND = H - Math.round(12 * SCALE);

    windows = (W < 640)
      ? [ { x: W * 0.08, y: H * 0.42, w: W * 0.56, h: H * 0.42, title: 'Terminal' } ]
      : [ { x: W * 0.06, y: H * 0.38, w: W * 0.34, h: H * 0.48, title: 'Terminal' },
          { x: W * 0.52, y: H * 0.24, w: W * 0.38, h: H * 0.60, title: 'Notes' } ];

    dog.x = clamp(dog.x, 26, W - 26);
    if (dog.surface === null || !windows[dog.surface]) {
      dog.surface = null;
      dog.y = GROUND;
    }
  }

  /* ── the dog ───────────────────────────────────────────────────────────── */

  var dog = {
    x: 120, y: 0,          // x = centre, y = the floor line his feet sit on
    vx: 0, vy: 0,
    facing: 'south-east',
    state: 'idle',
    t: 0,                  // seconds left in the current state
    frame: 0,              // seconds elapsed, drives animation cadence
    target: null,          // {x, y, then}
    surface: null,         // null = ground, else index into windows[]
    climbTarget: null,
    hopFrom: null, hopTo: null, hopT: 0, hopDur: 0, hopSurface: null
  };

  var particles = [];
  var pointer = { x: 0, y: 0, inside: false };

  function facingFrom(dx, dy) {
    var a = Math.atan2(dy, dx) * 180 / Math.PI;   // 0 = east, +90 = south
    var i = Math.round(((a + 360) % 360) / 45) % 8;
    return ['east', 'south-east', 'south', 'south-west',
            'west', 'north-west', 'north', 'north-east'][i];
  }

  function setState(s, seconds) {
    dog.state = s;
    dog.t = seconds || 0;
    dog.frame = 0;
  }

  /* Weighted autonomy — the shape of the app's table, minus the one involving
     a pile, which nobody wants on a download page. */
  var AUTONOMY = [
    ['wander', 40], ['nap', 15], ['sniff', 12], ['spin', 10],
    ['zoomies', 8], ['climb', 5], ['bark', 4]
  ];

  function roll() {
    var total = 0, i;
    for (i = 0; i < AUTONOMY.length; i++) total += AUTONOMY[i][1];
    var r = Math.random() * total;
    for (i = 0; i < AUTONOMY.length; i++) {
      r -= AUTONOMY[i][1];
      if (r <= 0) return AUTONOMY[i][0];
    }
    return 'wander';
  }

  function decide() {
    // A pointer inside the panel is the most interesting thing in the world.
    if (pointer.inside && Math.random() < 0.45) return startSniff();

    var choice = roll();
    if (choice === 'climb' && windows.length === 0) choice = 'wander';
    if (dog.surface !== null && choice !== 'nap') choice = 'patrol';

    switch (choice) {
      case 'wander':  return walkTo(rand(40, W - 40), GROUND);
      case 'nap':     return setState('sleep', rand(5, 9));
      case 'sniff':   return startSniff();
      case 'spin':    return setState('spin', 0.9);
      case 'zoomies': return startZoomies();
      case 'climb':   return startClimb();
      case 'bark':    return doBark();
      case 'patrol':  return startPatrol();
    }
  }

  function walkTo(x, y) {
    dog.target = { x: x, y: y, then: null };
    setState('walk', 0);
  }

  function startSniff() {
    if (!pointer.inside) return walkTo(rand(40, W - 40), GROUND);
    setState('seek', 0);
  }

  function startZoomies() {
    var a = rand(0, Math.PI * 2);
    dog.vx = Math.cos(a) * 340;
    dog.vy = Math.sin(a) * 90;
    setState('zoomies', rand(4.5, 7));
  }

  function doBark() {
    setState('bark', 1.2);
    for (var i = 0; i < 3; i++) {
      particles.push({
        kind: 'puff',
        x: dog.x + (dog.facing.indexOf('west') >= 0 ? -22 : 22),
        y: dog.y - 40 * SCALE / 2.2,
        vx: rand(-14, 14), vy: rand(-26, -12),
        life: 0.6, age: 0, frame: i % 3
      });
    }
  }

  /* ── climbing ──────────────────────────────────────────────────────────── */

  function startClimb() {
    var w = windows[(Math.random() * windows.length) | 0];
    if (!w) return walkTo(rand(40, W - 40), GROUND);
    dog.climbTarget = w;
    var edge = dog.x < w.x + w.w / 2 ? w.x + 20 : w.x + w.w - 20;
    dog.target = { x: clamp(edge, 30, W - 30), y: GROUND, then: 'hop' };
    setState('walk', 0);
  }

  function beginHop(w) {
    var idx = windows.indexOf(w);
    if (idx < 0) return decide();
    dog.hopFrom = { x: dog.x, y: dog.y };
    dog.hopTo = { x: clamp(dog.x, w.x + 18, w.x + w.w - 18), y: w.y + TITLEBAR };
    dog.hopT = 0;
    dog.hopDur = 0.55;
    dog.hopSurface = idx;
    setState('hop', 0);
  }

  function startPatrol() {
    var w = windows[dog.surface];
    if (!w) { dog.surface = null; dog.y = GROUND; return decide(); }
    var left = w.x + 18, right = w.x + w.w - 18;
    var goRight = dog.x < (left + right) / 2;
    dog.target = { x: goRight ? right : left, y: w.y + TITLEBAR, then: 'peek' };
    setState('walk', 0);
  }

  function fallOff() {
    dog.surface = null;
    dog.target = null;
    dog.vy = 0;
    setState('fall', 0);
  }

  /* ── pointer: petting the dog, dragging the windows ────────────────────── */

  function canvasPoint(e) {
    var r = canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  var drag = null;

  function hitTitlebar(p) {
    for (var i = windows.length - 1; i >= 0; i--) {
      var w = windows[i];
      if (p.x >= w.x && p.x <= w.x + w.w && p.y >= w.y && p.y <= w.y + TITLEBAR) return w;
    }
    return null;
  }

  function hitDog(p) {
    var half = 24 * SCALE / 2.2;
    return Math.abs(p.x - dog.x) < half && p.y > dog.y - half * 2.6 && p.y < dog.y + 10;
  }

  function pet() {
    setState('sit', 2.2);
    for (var i = 0; i < 4; i++) {
      particles.push({
        kind: 'heart', x: dog.x + rand(-12, 12), y: dog.y - 40 * SCALE / 2.2,
        vx: rand(-10, 10), vy: rand(-40, -26), life: 1.4, age: 0
      });
    }
  }

  canvas.addEventListener('pointermove', function (e) {
    var p = canvasPoint(e);
    pointer.x = p.x; pointer.y = p.y; pointer.inside = true;

    if (drag) {
      var nx = clamp(p.x - drag.dx, -drag.win.w * 0.35, W - drag.win.w * 0.65);
      var ny = clamp(p.y - drag.dy, 16, GROUND - TITLEBAR - 30);
      var moved = nx - drag.win.x;
      drag.win.x = nx;
      drag.win.y = ny;

      // He rides the window — until the drag is violent enough to shake him off.
      if (windows[dog.surface] === drag.win) {
        dog.x += moved;
        dog.y = drag.win.y + TITLEBAR;
        if (dog.target) { dog.target.x += moved; dog.target.y = dog.y; }
        if (Math.abs(moved) > 11) fallOff();
      }
      return;
    }
    canvas.style.cursor = hitTitlebar(p) ? 'grab' : (hitDog(p) ? 'pointer' : 'crosshair');
  });

  canvas.addEventListener('pointerleave', function () {
    pointer.inside = false;
    if (dog.state === 'seek' || dog.state === 'sniffing') decide();
  });

  canvas.addEventListener('pointerdown', function (e) {
    var p = canvasPoint(e);
    if (hitDog(p)) { pet(); return; }
    var w = hitTitlebar(p);
    if (w) {
      drag = { win: w, dx: p.x - w.x, dy: p.y - w.y };
      canvas.style.cursor = 'grabbing';
      if (canvas.setPointerCapture) canvas.setPointerCapture(e.pointerId);
    }
  });

  function endDrag(e) {
    if (!drag) return;
    drag = null;
    canvas.style.cursor = 'crosshair';
    try {
      if (e && e.pointerId != null && canvas.hasPointerCapture &&
          canvas.hasPointerCapture(e.pointerId)) {
        canvas.releasePointerCapture(e.pointerId);
      }
    } catch (err) { /* nothing to release */ }
  }
  canvas.addEventListener('pointerup', endDrag);
  canvas.addEventListener('pointercancel', endDrag);

  /* ── update ────────────────────────────────────────────────────────────── */

  var SPIN_ORDER = ['south', 'south-west', 'west', 'north-west',
                    'north', 'north-east', 'east', 'south-east'];

  function update(dt) {
    dog.frame += dt;
    var w, speed, dx, dy, dist, k;

    switch (dog.state) {

      case 'idle':
        dog.t -= dt;
        if (dog.t <= 0) decide();
        break;

      case 'walk':
        if (!dog.target) { setState('idle', rand(1.0, 2.4)); break; }
        speed = dog.surface === null ? 66 : 44;
        dx = dog.target.x - dog.x;
        dy = dog.target.y - dog.y;
        dist = Math.hypot(dx, dy);
        if (dist < 3) {
          var then = dog.target.then;
          dog.target = null;
          if (then === 'hop') beginHop(dog.climbTarget);
          else if (then === 'peek') { dog.facing = 'south'; setState('peek', rand(1.2, 2.2)); }
          else setState('idle', rand(1.0, 2.6));
          break;
        }
        dog.facing = facingFrom(dx, dy);
        dog.x += (dx / dist) * speed * dt;
        dog.y += (dy / dist) * speed * dt;
        if (dog.surface !== null) {
          w = windows[dog.surface];
          if (w && (dog.x < w.x + 5 || dog.x > w.x + w.w - 5)) fallOff();
        }
        break;

      case 'seek':                       // trotting toward the pointer
        if (!pointer.inside) { decide(); break; }
        dx = pointer.x - dog.x;
        dy = clamp(pointer.y, GROUND - 4, GROUND) - dog.y;
        dist = Math.hypot(dx, dy);
        if (dist < 52) { setState('sniffing', rand(3.5, 7)); break; }
        dog.facing = facingFrom(dx, dy);
        dog.x += (dx / dist) * 78 * dt;
        dog.y += (dy / dist) * 78 * dt;
        break;

      case 'sniffing':
        dog.t -= dt;
        if (pointer.inside) {
          dx = pointer.x - dog.x;
          if (Math.abs(dx) > 3) dog.facing = facingFrom(dx, 0.2);
          dog.x += clamp(dx, -1, 1) * 26 * dt;
        }
        if (dog.t <= 0) {
          // Six times out of ten a finished sniff escalates.
          if (Math.random() < 0.6 && pointer.inside) setState('stalking', 0.9);
          else setState('idle', rand(0.8, 1.8));
        }
        break;

      case 'stalking':
        dog.t -= dt;
        if (pointer.inside) dog.facing = facingFrom(pointer.x - dog.x, 0.2);
        if (dog.t <= 0) {
          var tx = pointer.inside ? pointer.x : dog.x + rand(-70, 70);
          dog.hopFrom = { x: dog.x, y: dog.y };
          dog.hopTo = { x: clamp(tx, 26, W - 26), y: GROUND };
          dog.hopT = 0; dog.hopDur = 0.42; dog.hopSurface = null;
          setState('pouncing', 0);
        }
        break;

      case 'spin':
        dog.t -= dt;
        dog.facing = SPIN_ORDER[Math.floor(dog.frame * 9) % 8];
        if (dog.t <= 0) setState('idle', rand(0.6, 1.6));
        break;

      case 'zoomies':
        dog.t -= dt;
        dog.x += dog.vx * dt;
        dog.y += dog.vy * dt;
        if (dog.x < 26)      { dog.x = 26;      dog.vx = Math.abs(dog.vx); }
        if (dog.x > W - 26)  { dog.x = W - 26;  dog.vx = -Math.abs(dog.vx); }
        if (dog.y < GROUND - 46) { dog.y = GROUND - 46; dog.vy = Math.abs(dog.vy); }
        if (dog.y > GROUND)      { dog.y = GROUND;      dog.vy = -Math.abs(dog.vy); }
        dog.facing = facingFrom(dog.vx, dog.vy);
        if (Math.random() < dt * 6) {
          particles.push({ kind: 'dust', x: dog.x, y: dog.y,
                           vx: rand(-8, 8), vy: rand(-6, 0), life: 0.45, age: 0 });
        }
        if (dog.t <= 0) setState('idle', rand(0.8, 1.6));
        break;

      case 'bark':
      case 'peek':
      case 'sit':
      case 'sleep':
        dog.t -= dt;
        if (dog.t <= 0) {
          if (dog.state === 'peek' && dog.surface !== null) {
            if (Math.random() < 0.45) fallOff();     // hops down
            else startPatrol();
          } else setState('idle', rand(0.9, 2.2));
        }
        break;

      case 'hop':
      case 'pouncing':
        dog.hopT += dt;
        k = Math.min(1, dog.hopT / dog.hopDur);
        dog.x = dog.hopFrom.x + (dog.hopTo.x - dog.hopFrom.x) * k;
        dog.y = dog.hopFrom.y + (dog.hopTo.y - dog.hopFrom.y) * k
                - Math.sin(k * Math.PI) * (dog.state === 'hop' ? 46 : 30);
        dog.facing = facingFrom(dog.hopTo.x - dog.hopFrom.x,
                                (dog.hopTo.y - dog.hopFrom.y) || 0.2);
        if (k >= 1) {
          var wasHop = dog.state === 'hop';
          dog.surface = dog.hopSurface;
          dog.y = dog.hopTo.y;
          puffDust();
          if (wasHop) startPatrol();
          else setState('idle', rand(0.7, 1.5));
        }
        break;

      case 'fall':
        dog.vy += 900 * dt;
        dog.y += dog.vy * dt;
        dog.facing = facingFrom(0.2, 1);
        if (dog.y >= GROUND) {
          dog.y = GROUND;
          dog.vy = 0;
          puffDust();
          setState('landing', 0.35);
        }
        break;

      case 'landing':
        dog.t -= dt;
        if (dog.t <= 0) setState('idle', rand(0.5, 1.2));
        break;
    }

    dog.x = clamp(dog.x, 22, W - 22);

    // Standing on a window that has since moved (or gone).
    if (dog.surface !== null) {
      w = windows[dog.surface];
      if (!w) fallOff();
      else if (dog.state !== 'hop' && dog.state !== 'fall') dog.y = w.y + TITLEBAR;
    }

    for (var i = particles.length - 1; i >= 0; i--) {
      var p = particles[i];
      p.age += dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      if (p.kind === 'heart') p.vy -= 12 * dt;
      if (p.age >= p.life) particles.splice(i, 1);
    }
  }

  function puffDust() {
    for (var i = 0; i < 4; i++) {
      particles.push({ kind: 'dust', x: dog.x + rand(-10, 10), y: dog.y,
                       vx: rand(-24, 24), vy: rand(-14, -4), life: 0.4, age: 0 });
    }
  }

  /* ── draw ──────────────────────────────────────────────────────────────── */

  function spriteFor() {
    var d = dog.facing;
    switch (dog.state) {
      case 'walk':     return sprites[(Math.floor(dog.frame * 4)  % 2 ? 'run2_' : 'run1_') + d];
      case 'seek':     return sprites[(Math.floor(dog.frame * 6)  % 2 ? 'run2_' : 'run1_') + d];
      case 'zoomies':  return sprites[(Math.floor(dog.frame * 13) % 2 ? 'run2_' : 'run1_') + d];
      case 'sniffing': return sprites['sniff_' + d];
      case 'stalking': return sprites['stalk_' + d];
      case 'pouncing': return sprites['pounce_' + d];
      case 'hop':
      case 'fall':     return sprites['run2_' + d];
      case 'landing':  return sprites['pounce_' + d];
      case 'sit':      return sprites['sit_' + d];
      case 'sleep':    return sprites['sleep_' + d];
      case 'bark':     return sprites['bark_' + d];
      case 'peek':     return sprites['peek_' + d];
      default:         return sprites['idle_' + d];
    }
  }

  function drawSprite(rec, cx, floorY, scale, alpha) {
    if (!rec || !rec.img.complete || !rec.img.naturalWidth) return;
    var b = rec.box || { x0: 0, y0: 0, w: rec.img.naturalWidth, h: rec.img.naturalHeight };
    var dw = b.w * scale, dh = b.h * scale;
    if (alpha != null) { ctx.save(); ctx.globalAlpha = Math.max(0, Math.min(1, alpha)); }
    ctx.drawImage(rec.img, b.x0, b.y0, b.w, b.h,
                  Math.round(cx - dw / 2), Math.round(floorY - dh),
                  Math.round(dw), Math.round(dh));
    if (alpha != null) ctx.restore();
  }

  function roundRect(x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function drawWindow(w) {
    ctx.save();
    ctx.shadowColor = 'rgba(0,0,0,0.45)';
    ctx.shadowBlur = 18;
    ctx.shadowOffsetY = 8;
    ctx.fillStyle = '#F4EDE2';
    roundRect(w.x, w.y, w.w, w.h, 8);
    ctx.fill();
    ctx.restore();

    ctx.save();
    roundRect(w.x, w.y, w.w, w.h, 8);
    ctx.clip();

    ctx.fillStyle = '#E2D6C4';
    ctx.fillRect(w.x, w.y, w.w, TITLEBAR);
    ctx.fillStyle = 'rgba(27,26,29,0.18)';
    ctx.fillRect(w.x, w.y + TITLEBAR - 1, w.w, 1);

    var lights = ['#E4685A', '#E5B14A', '#5FBB55'];
    for (var i = 0; i < 3; i++) {
      ctx.beginPath();
      ctx.arc(w.x + 14 + i * 15, w.y + TITLEBAR / 2, 4.5, 0, Math.PI * 2);
      ctx.fillStyle = lights[i];
      ctx.fill();
    }
    ctx.fillStyle = 'rgba(27,26,29,0.55)';
    ctx.font = '10px ui-monospace, Menlo, monospace';
    ctx.textAlign = 'center';
    ctx.fillText(w.title, w.x + w.w / 2, w.y + TITLEBAR / 2 + 3.5);

    // Faint content lines, so it reads as a window rather than a card.
    ctx.fillStyle = 'rgba(27,26,29,0.10)';
    var lineY = w.y + TITLEBAR + 16, n = 0;
    while (lineY < w.y + w.h - 10) {
      var frac = 0.42 + ((n * 37) % 53) / 100;
      ctx.fillRect(w.x + 16, lineY, (w.w - 32) * frac, 4);
      lineY += 13; n++;
    }
    ctx.restore();

    ctx.strokeStyle = 'rgba(27,26,29,0.75)';
    ctx.lineWidth = 2;
    roundRect(w.x + 1, w.y + 1, w.w - 2, w.h - 2, 8);
    ctx.stroke();
  }

  function draw() {
    ctx.clearRect(0, 0, W, H);

    var g = ctx.createLinearGradient(0, GROUND - 40, 0, H);
    g.addColorStop(0, 'rgba(255,240,220,0.04)');
    g.addColorStop(1, 'rgba(255,240,220,0.16)');
    ctx.fillStyle = g;
    ctx.fillRect(0, GROUND - 40, W, H - GROUND + 40);
    ctx.fillStyle = 'rgba(255,242,225,0.22)';
    ctx.fillRect(0, GROUND, W, 1);

    windows.forEach(drawWindow);

    if (!ready) return;

    var sh = props['shadow_blob'];
    if (sh) drawSprite(sh, dog.x, dog.y + 5, SCALE * 0.85, 0.45);

    drawSprite(spriteFor(), dog.x, dog.y + 2, SCALE);

    particles.forEach(function (p) {
      var k = 1 - p.age / p.life;
      var rec = p.kind === 'heart' ? props['heart']
              : p.kind === 'puff'  ? props['bark_puff_' + (p.frame || 0)]
              : props['dust_' + Math.min(3, Math.floor((p.age / p.life) * 4))];
      drawSprite(rec, p.x, p.y, SCALE * 0.7, k);
    });
  }

  /* ── loop ──────────────────────────────────────────────────────────────── */

  var last = 0, running = false, rafId = 0, tick = 0;
  var reduce = !!(window.matchMedia &&
                  window.matchMedia('(prefers-reduced-motion: reduce)').matches);

  function frame(now) {
    if (!running) return;
    var dt = last ? Math.min(0.05, (now - last) / 1000) : 0;
    last = now;
    update(dt);
    draw();
    rafId = requestAnimationFrame(frame);
  }

  function start() {
    if (running || reduce) return;
    running = true; last = 0;
    rafId = requestAnimationFrame(frame);
    if (!tick) tick = setInterval(function () {
      if (running && ready && !last) { update(1 / 30); draw(); }
    }, 33);
  }
  function stop() {
    running = false;
    if (rafId) cancelAnimationFrame(rafId);
  }

  window.addEventListener('resize', function () { layout(); if (!running) draw(); });
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) stop(); else start();
  });

  // Don't burn a frame budget on a panel nobody is looking at.
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(function (entries) {
      if (entries[0].isIntersecting) start(); else stop();
    }, { threshold: 0.01 }).observe(canvas);
  }

  layout();
  dog.y = GROUND;
  dog.x = W * 0.28;
  setState('idle', 1.2);

  // Paint as soon as the sprites land, whether or not rAF is running: a throttled
  // or offscreen frame must still show a dog, not an empty panel.
  (function paintWhenReady() {
    if (ready) { draw(); }
    else setTimeout(paintWhenReady, 60);
  })();

  if (reduce) {
    // Respect the setting: one still frame, plus an explicit opt-in to motion.
    var btn = document.querySelector('[data-motion-toggle]');
    (function sitWhenReady() {
      if (ready) { setState('sit', 9999); draw(); }
      else setTimeout(sitWhenReady, 80);
    })();
    if (btn) {
      btn.hidden = false;
      btn.addEventListener('click', function () {
        btn.hidden = true;
        reduce = false;
        setState('idle', 0.4);
        start();
      });
    }
  } else {
    start();
  }
};

