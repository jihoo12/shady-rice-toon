// Toon's wallpaper: a cartoon sky over rolling hills, in flat colours with
// ink outlines. By day a smiling sun turns its rays and blinks; at dusk it
// sinks into a pink sky; at night a sleepy moon and twinkling stars come
// out. Puffy clouds drift across all day long.
//
// The shell passes the hour (0..24) and redraws now and then, so the sky
// follows the day. Everything is measured in logical pixels, so the ink
// lines are the same width on every screen.
//
// The surface's own drawing (u_tex) goes on top, so the lock screen can
// stand on the same sky.
//
// Uniforms: hour (0..24), ink, accent (colours).

uniform sampler2D u_tex;
uniform vec2 u_size;
uniform float u_time;
uniform float u_hour;
uniform vec4 u_ink;
uniform vec4 u_accent;

varying vec2 v_uv;
varying vec2 v_local;

const float TAU = 6.2831853;
const float LINE = 3.0;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// 1 inside a signed distance (in pixels), 0 outside, a pixel of softness.
float inside(float d) {
    return clamp(0.5 - d, 0.0, 1.0);
}

// A shape filled with `fill` and outlined in ink.
vec3 inked(vec3 col, float d, vec3 fill, float alpha) {
    col = mix(col, fill, inside(d) * alpha);
    return mix(col, u_ink.rgb, inside(abs(d) - LINE * 0.5) * alpha);
}

float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

float circle(vec2 p, vec2 c, float r) {
    return length(p - c) - r;
}

// A puffy cloud with a flat bottom, centred on c, of size r.
float cloud(vec2 p, vec2 c, float r) {
    vec2 q = p - c;
    float d = circle(q, vec2(0.0, -0.15 * r), r);
    d = smin(d, circle(q, vec2(-0.95 * r, 0.25 * r), 0.68 * r), 6.0);
    d = smin(d, circle(q, vec2(0.95 * r, 0.2 * r), 0.74 * r), 6.0);
    d = smin(d, circle(q, vec2(1.75 * r, 0.5 * r), 0.42 * r), 6.0);
    d = smin(d, circle(q, vec2(-1.7 * r, 0.55 * r), 0.36 * r), 6.0);
    return max(d, q.y - 0.72 * r);
}

// The top of a hill at x, in pixels from the top.
float hill(float x, float base, float amp, float freq, float phase) {
    float u = x / max(u_size.x, 1.0) * TAU;
    return u_size.y * (base + amp * sin(u * freq + phase) + amp * 0.45 * sin(u * freq * 2.7 + phase * 1.7));
}

// Signed distance to a hill's top edge: negative below it, in the hill.
float hill_d(vec2 p, float base, float amp, float freq, float phase) {
    float h = hill(p.x, base, amp, freq, phase);
    float s = (hill(p.x + 1.0, base, amp, freq, phase) - hill(p.x - 1.0, base, amp, freq, phase)) * 0.5;
    return (h - p.y) / sqrt(1.0 + s * s);
}

void main() {
    vec2 p = v_local * u_size;
    float W = u_size.x, H = u_size.y;
    float t = u_time;
    float hr = mod(u_hour, 24.0);

    // How much of the day, dusk and night there is in the sky now.
    float night = 1.0 - smoothstep(5.0, 6.5, hr) + smoothstep(19.5, 21.0, hr);
    float dusk = (smoothstep(5.0, 6.5, hr) - smoothstep(7.0, 8.5, hr))
        + (smoothstep(16.5, 18.0, hr) - smoothstep(19.5, 21.0, hr));
    night = clamp(night, 0.0, 1.0);
    dusk = clamp(dusk, 0.0, 1.0 - night);
    float day = clamp(1.0 - night - dusk, 0.0, 1.0);

    vec3 top = day * vec3(0.30, 0.70, 1.00) + dusk * vec3(0.44, 0.36, 0.86) + night * vec3(0.08, 0.07, 0.22);
    vec3 mid = day * vec3(0.55, 0.83, 1.00) + dusk * vec3(1.00, 0.56, 0.64) + night * vec3(0.17, 0.14, 0.40);
    vec3 low = day * vec3(0.80, 0.94, 1.00) + dusk * vec3(1.00, 0.78, 0.45) + night * vec3(0.28, 0.24, 0.55);

    // The sky in three flat bands, as a cel would paint it.
    float horizon = H * 0.78;
    float y = clamp(p.y / horizon, 0.0, 1.0);
    float upper = inside(p.y - H * 0.27);
    float middle = inside(p.y - H * 0.52);
    vec3 col = mix(low, mix(mid, top, upper), middle);

    // Halftone dots near the top, a comic book's print.
    vec2 cell = mod(p, 16.0) - 8.0;
    float dot_r = 3.6 * (1.0 - smoothstep(0.0, 0.45, y));
    col = mix(col, mix(col, vec3(1.0), 0.16 + 0.1 * night), inside(length(cell) - dot_r));

    // Stars, at night.
    if (night > 0.0) {
        vec2 sc = floor(p / 58.0);
        float h = hash(sc);
        if (h > 0.7 && p.y < H * 0.7) {
            vec2 sp = (sc + vec2(0.2 + 0.6 * hash(sc + 3.1), 0.2 + 0.6 * hash(sc + 7.7))) * 58.0;
            float tw = 0.65 + 0.35 * sin(t * (1.5 + 2.0 * h) + h * 40.0);
            vec2 q = abs(p - sp);
            // A four-pointed sparkle.
            float d = min(length(q * vec2(1.0, 0.28)), length(q * vec2(0.28, 1.0))) - 2.6 * tw;
            col = mix(col, vec3(1.0, 0.96, 0.78), inside(d) * night);
        }
    }

    // The sun: by day high on the right, at dusk low and orange.
    float sun_on = day + dusk;
    if (sun_on > 0.0) {
        float r = H * 0.075;
        vec2 c = vec2(W * 0.80, H * mix(0.22, 0.50, dusk));
        vec2 q = p - c;
        float dist = length(q);
        vec3 gold = mix(vec3(1.0, 0.84, 0.25), vec3(1.0, 0.58, 0.30), dusk);
        // Rays that turn slowly and breathe.
        float n = 12.0;
        float ang = atan(q.y, q.x) + t * 0.12;
        float r1 = r * 1.28, r2 = r * (1.75 + 0.08 * sin(t * 1.3));
        float arc = abs(fract(ang * n / TAU) - 0.5) * TAU / n * dist;
        float k = clamp((dist - r1) / (r2 - r1), 0.0, 1.0);
        float ray = max(arc - mix(r * 0.2, 2.5, k), max(r1 - dist, dist - r2));
        col = inked(col, ray, gold, sun_on);
        col = inked(col, dist - r, gold, sun_on);
        // Its face: eyes that blink every few seconds, cheeks and a smile.
        float blink = 1.0 - 0.88 * step(0.965, fract(t / 4.7));
        vec2 e = vec2(r * 0.34, r * 0.16);
        float eyes = min(length((q - vec2(-e.x, -e.y)) * vec2(1.0, 1.0 / blink)),
                         length((q - vec2(e.x, -e.y)) * vec2(1.0, 1.0 / blink))) - r * 0.11;
        col = mix(col, u_ink.rgb, inside(eyes) * sun_on);
        float cheeks = min(length(q - vec2(-r * 0.58, r * 0.2)), length(q - vec2(r * 0.58, r * 0.2))) - r * 0.13;
        col = mix(col, mix(gold, u_accent.rgb, 0.6), inside(cheeks) * sun_on);
        float smile = max(abs(length(q - vec2(0.0, r * 0.02)) - r * 0.42) - LINE * 0.5, -q.y + r * 0.18);
        col = mix(col, u_ink.rgb, inside(smile) * sun_on);
    }

    // The moon: a sleepy crescent at night.
    if (night > 0.0) {
        float r = H * 0.07;
        vec2 c = vec2(W * 0.84, H * 0.2);
        vec2 q = p - c;
        float d = max(length(q) - r, -(length(q - vec2(r * 0.55, -r * 0.3)) - r * 0.85));
        col = inked(col, d, vec3(1.0, 0.93, 0.62), night);
        // A closed eye.
        vec2 eq = q - vec2(-r * 0.48, -r * 0.05);
        float eye = max(abs(length(eq) - r * 0.17) - 1.2, -eq.y);
        col = mix(col, u_ink.rgb, inside(eye) * night);
    }

    // Clouds, drifting right and coming round again.
    vec3 white = day * vec3(1.0) + dusk * vec3(1.0, 0.89, 0.93) + night * vec3(0.42, 0.38, 0.68);
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float r = H * (0.045 + 0.022 * hash(vec2(fi, 1.0)));
        float span = W + 8.0 * r;
        // Spread across the sky, at speeds close enough that they seldom bunch.
        float speed = 5.0 + 2.5 * hash(vec2(fi, 2.0));
        float x = mod(span * (0.13 + 0.37 * fi) + t * speed, span) - 4.0 * r;
        float cy = H * (0.11 + 0.095 * fi + 0.03 * hash(vec2(fi, 4.0)));
        // A gentle bob.
        cy += 3.0 * sin(t * 0.6 + fi * 1.9);
        col = inked(col, cloud(p, vec2(x, cy), r), white, 1.0);
    }

    // Hills: a far one and a near one, each with a lit rim under its line.
    vec3 far = day * vec3(0.55, 0.86, 0.48) + dusk * vec3(0.80, 0.50, 0.70) + night * vec3(0.18, 0.33, 0.42);
    vec3 near = day * vec3(0.32, 0.76, 0.42) + dusk * vec3(0.56, 0.36, 0.64) + night * vec3(0.11, 0.23, 0.32);
    float d1 = hill_d(p, 0.76, 0.035, 1.3, 1.0);
    col = inked(col, d1, far, 1.0);
    col = mix(col, mix(far, vec3(1.0), 0.28), inside(-d1 - LINE) * inside(d1 + 10.0));
    float d2 = hill_d(p, 0.86, 0.04, 0.9, 2.6);
    col = inked(col, d2, near, 1.0);
    col = mix(col, mix(near, vec3(1.0), 0.22), inside(-d2 - LINE) * inside(d2 + 12.0));

    // Little flowers on the near hill.
    vec2 fc = floor(p / vec2(90.0, 60.0));
    float fh = hash(fc + 11.0);
    vec2 fp = (fc + vec2(0.3 + 0.4 * hash(fc + 5.0), 0.5)) * vec2(90.0, 60.0);
    if (fh > 0.55 && hill_d(fp, 0.86, 0.04, 0.9, 2.6) < -16.0) {
        vec2 q = p - fp;
        float a = atan(q.y, q.x);
        float petals = length(q) - (6.0 + 2.5 * cos(a * 5.0));
        vec3 petal = fh > 0.8 ? vec3(1.0, 0.85, 0.3) : (fh > 0.68 ? u_accent.rgb : vec3(1.0));
        col = inked(col, petals, mix(petal, near, night * 0.5), 1.0);
        col = mix(col, vec3(1.0, 0.75, 0.2), inside(length(q) - 2.5));
    }

    vec4 ui = texture2D(u_tex, v_uv);
    gl_FragColor = vec4(ui.rgb + col * (1.0 - ui.a), 1.0);
}
