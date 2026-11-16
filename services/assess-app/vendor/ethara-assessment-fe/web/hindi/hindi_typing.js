// Hindi typing: which Devanagari spellings to offer for the English letters a tasker types (mera -> मेरा).
//
// The workbench and the review app already turn a typed word into Devanagari by spelling rules (hindiRules in their own
// scripts). Those rules guess vowel length, थ/ठ, joined letters and nasals letter by letter, and get about half of real
// Hinglish wrong. This module ranks the spellings instead, and the rules' own options stay as the fallback:
//   1. every plausible spelling of the letters typed is generated (short or long vowel, थ/ठ, त/ट, joined or not, nasal);
//   2. only real Hindi words are kept, ranked by how common they are (hindi_dictionary.js); a spelling that drops a vowel
//      the tasker typed (samjha -> समझ) or uses a rare reading (dh -> द) ranks lower;
//   3. how people actually romanize each word (hindi_romanizations.js, from Google Dakshina) reorders the common ones;
//   4. between spellings of one word the client's form wins: nukta and chandrabindu (ख़राब, पहुँच); ए or ये goes by
//      which is commoner (गए, लिए, but रुपये as the client writes it);
//   5. English words stay in English letters when they are clearly English (hindi_english.js), as the 0915
//      conventions ask; backchannels come out as the conventions table spells them (hmm -> हम्म, na-na -> ना-ना);
//   6. a short list covers chat spellings no rule reaches (nahi -> नहीं, hum -> हम).
// Nothing is a model and nothing leaves the browser: the data files are word lists with counts.
window.StrixHindi = (function () {
  const WORDS = window.STRIX_HI_WORDS || [], FREQ = window.STRIX_HI_FREQ || [], N = WORDS.length, EN = window.STRIX_EN_ZIPF || {};
  const HI_TOTAL = FREQ.reduce((a, b) => a + b, 0);

  function lowerBound(p) {
    let lo = 0, hi = N;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (WORDS[mid] < p) lo = mid + 1; else hi = mid; }
    return lo;
  }
  const hasPrefix = (p) => { const i = lowerBound(p); return i < N && WORDS[i].startsWith(p); };
  const freqOf = (w) => { const i = lowerBound(w); return i < N && WORDS[i] === w ? FREQ[i] : 0; };
  const hiZipf = (w) => { const f = freqOf(w); return f ? Math.log10(f / HI_TOTAL * 1e9) : 0; };

  const CONS = [
    ["chh", ["छ"]], ["ksh", ["क्ष"]], ["shr", ["श्र"]], ["gy", ["ज्ञ", "ग्य"]], ["tr", ["त्र"]],
    ["kh", ["ख", "ख़"]], ["gh", ["घ", "ग़"]], ["ch", ["च", "छ"]], ["jh", ["झ"]], ["Th", ["ठ"]], ["Dh", ["ढ"]],
    ["th", ["थ", "ठ", "त"]], ["dh", ["ध", "ढ", "ढ़", "द"]], ["ph", ["फ", "फ़"]], ["bh", ["भ"]], ["sh", ["श", "ष"]],
    ["rh", ["ढ़"]], ["k", ["क"]], ["g", ["ग"]], ["c", ["क", "च", "स"]], ["j", ["ज", "ज़"]], ["T", ["ट"]],
    ["D", ["ड"]], ["N", ["ण"]], ["t", ["त", "ट"]], ["d", ["द", "ड", "ड़"]], ["n", ["न", "ण"]], ["p", ["प"]],
    ["b", ["ब"]], ["m", ["म"]], ["y", ["य"]], ["r", ["र", "ड़"]], ["l", ["ल"]], ["v", ["व"]], ["w", ["व"]],
    ["s", ["स", "श"]], ["h", ["ह"]], ["f", ["फ़", "फ"]], ["z", ["ज़", "ज"]], ["q", ["क़", "क"]], ["x", ["क्स"]],
  ];
  const VOW = [
    ["aon", [["आँव", "ाँव"], ["आंव", "ांव"]]], ["aa", [["आ", "ा"]]], ["ai", [["ऐ", "ै"], ["ए", "े"], ["आई", "ाई"]]],
    ["au", [["औ", "ौ"]]], ["ee", [["ई", "ी"]]], ["ii", [["ई", "ी"]]], ["oo", [["ऊ", "ू"], ["ओ", "ो"]]],
    ["uu", [["ऊ", "ू"]]], ["ei", [["ए", "े"], ["ई", "ी"]]], ["ri", [["ऋ", "ृ"]]], ["a", [["अ", ""], ["आ", "ा"]]],
    ["i", [["इ", "ि"], ["ई", "ी"]]], ["u", [["उ", "ु"], ["ऊ", "ू"]]], ["e", [["ए", "े"], ["ऐ", "ै"], ["", ""]]],
    ["o", [["ओ", "ो"], ["औ", "ौ"], ["ऑ", "ॉ"]]],
  ];
  const VIRAMA = "्", NASALS = ["ं", "ँ"];

  // Hindi backchannels (0915 table) typed in English letters, and fillers kept in English letters.
  const BACK = {
    hmm: "हम्म", hm: "हम्म", hmmm: "हम्म", mhm: "म्हम्", mhmm: "म्हम्", aha: "अहाँ", ahaan: "अहाँ", "mm-mm": "म्म्-म्म्",
    "na-na": "ना-ना", "naa-naa": "ना-ना", are: "अरे", arre: "अरे", arey: "अरे", wah: "वाह", waah: "वाह", um: "um",
  };

  // Chat spellings the rules cannot reach (or reach only as a rarer word). Checked before everything else.
  const CHAT = {
    nahi: ["नहीं"], nahin: ["नहीं"], nai: ["नहीं"], nhi: ["नहीं"], hum: ["हम"], woh: ["वह", "वो"], wo: ["वो", "वह"],
    yeh: ["यह", "ये"], ye: ["ये", "यह"], kyun: ["क्यों"], kyu: ["क्यों"], kyon: ["क्यों"], haan: ["हाँ"], han: ["हाँ"],
    main: ["मैं", "में"], mai: ["मैं"], mein: ["में", "मैं"], me: ["में", "मे"], hai: ["है"], hain: ["हैं"], h: ["है"],
    kya: ["क्या"], kyaa: ["क्या"], accha: ["अच्छा"], acha: ["अच्छा"], achha: ["अच्छा"], thik: ["ठीक"], theek: ["ठीक"],
    bahut: ["बहुत"], bohot: ["बहुत"], bhot: ["बहुत"], bht: ["बहुत"], kuch: ["कुछ"], kuchh: ["कुछ"], khana: ["खाना"],
    pani: ["पानी"], bhai: ["भाई"], didi: ["दीदी"], kaun: ["कौन"], kahan: ["कहाँ"], kaha: ["कहा", "कहाँ"],
    yahan: ["यहाँ"], wahan: ["वहाँ"], jahan: ["जहाँ"], lekin: ["लेकिन"], matlab: ["मतलब"], zindagi: ["ज़िंदगी"],
    pyar: ["प्यार"], pyaar: ["प्यार"], mujhe: ["मुझे"], tujhe: ["तुझे"], tumhe: ["तुम्हें"], tumhein: ["तुम्हें"],
    tmhe: ["तुम्हें"], humein: ["हमें"], hume: ["हमें"], unhe: ["उन्हें"], unhein: ["उन्हें"], kaise: ["कैसे"],
    kese: ["कैसे"], kaisa: ["कैसा"], kyunki: ["क्योंकि"], kyonki: ["क्योंकि"], isliye: ["इसलिए"], phir: ["फिर"],
    fir: ["फिर"], sirf: ["सिर्फ़"], zaroor: ["ज़रूर"], shayad: ["शायद"], paanch: ["पाँच"], ka: ["का"], tha: ["था"],
    sab: ["सब"], kal: ["कल"], toh: ["तो"], to: ["तो"], tho: ["तो"], kr: ["कर"], kro: ["करो"], rha: ["रहा"],
    rhi: ["रही"], rhe: ["रहे"], pta: ["पता"], mne: ["मैंने"], maine: ["मैंने"], gya: ["गया"], gyi: ["गई"],
    humko: ["हमको"], hamko: ["हमको"], maa: ["माँ"], ma: ["माँ", "मा"], thnx: ["thanks"], thx: ["thanks"],
    thanx: ["thanks"], unhone: ["उन्होंने"], unhon: ["उन्हों"], jinhone: ["जिन्होंने"], khatam: ["ख़त्म"], khatm: ["ख़त्म"], zidd: ["ज़िद"], zid: ["ज़िद"], plz: ["please"], pls: ["please"], ok: ["ok"], okay: ["okay"],
  };

  // ---- the client's preferred form between spellings of one word (both must be real words)
  const NUKTA_BASE = { "ख": "ख़", "ग": "ग़", "ज": "ज़", "फ": "फ़", "क": "क़" };
  const TOP_SIGNS = "िीेैोौ";  // a sign on the top line takes anusvara (ं); otherwise the nasal is chandrabindu (ँ)
  function variants(w) {
    const out = new Set([w]);
    const add = (x) => { if (x !== w) out.add(x); };
    add(w.replace(/ये/g, "ए").replace(/यी/g, "ई"));
    add(w.replace(/म्(?=[पफबभ])/g, "ं").replace(/न्(?=[तथदध])/g, "ं").replace(/ङ्(?=[कखगघ])/g, "ं")
         .replace(/ण्(?=[टठडढ])/g, "ं").replace(/ञ्(?=[चछजझ])/g, "ं"));
    for (const base of [...out]) {
      let chandra = "";
      for (let i = 0; i < base.length; i++) chandra += base[i] === "ं" && !TOP_SIGNS.includes(base[i - 1] || "") ? "ँ" : base[i];
      add(chandra);
      for (let i = 0; i < base.length; i++) if (NUKTA_BASE[base[i]]) add(base.slice(0, i) + NUKTA_BASE[base[i]] + base.slice(i + 1));
      add([...base].map((c) => NUKTA_BASE[c] || c).join(""));
    }
    return [...out];
  }
  const styleScore = (w) => (w.match(/[ख़ग़ज़फ़क़]|़/g) || []).length + (w.match(/ँ/g) || []).length
    - (w.match(/[मनङणञ]्(?=[क-ह])/g) || []).length;
  function preferred(w) {
    const f = freqOf(w);
    const ok = variants(w).filter((v) => v === w || freqOf(v) >= f * 0.03);
    return ok.sort((a, b) => styleScore(b) - styleScore(a) || freqOf(b) - freqOf(a))[0];
  }

  // A typed vowel that is not written (samjha -> समझ, dekhe -> देख, ped -> पद) and rare consonant readings
  // (dh -> द, th -> त) cost a penalty, so the spelling that honours what was typed wins over a shorter, commoner word.
  const RARE = { "dh": new Set(["द"]), "th": new Set(["त"]), "c": new Set(["स"]), "r": new Set(["ड़"]) };
  const penaltyOf = new Map();
  function candidates(latin, limit = 6000) {
    let s = latin.replace(/'/g, "");
    if (/^[A-Z][a-z]*$/.test(s)) s = s.toLowerCase();
    const out = new Set();
    const stack = [[0, "", false, 0]];
    let steps = 0;
    penaltyOf.clear();
    while (stack.length && steps++ < limit) {
      const [i, text, bare, pen] = stack.pop();
      if (i === s.length) {
        if (freqOf(text)) { out.add(text); if (!penaltyOf.has(text) || pen < penaltyOf.get(text)) penaltyOf.set(text, pen); }
        continue;
      }
      const rest = s.slice(i);
      for (const [lat, opts] of VOW) {
        if (!rest.startsWith(lat)) continue;
        for (const [ind, sign] of opts) {
          if (lat === "e" && ind === "" && !bare) continue;
          const t = text + (bare ? sign : ind);
          if (t && !hasPrefix(t)) continue;
          const atEnd = i + lat.length === s.length;
          // not writing a typed vowel: e dropped anywhere, or a final a left as the inherent vowel after a consonant
          const dropped = (lat === "e" && ind === "") || (atEnd && lat === "a" && bare && sign === "");
          const p2 = pen + (dropped ? 2 : 0);
          stack.push([i + lat.length, t, false, p2]);
          const nxt = s.slice(i + lat.length);
          if (nxt.startsWith("n") && (nxt.length === 1 || !"aeiou".includes(nxt[1]))) {
            for (const nas of NASALS) if (hasPrefix(t + nas)) stack.push([i + lat.length + 1, t + nas, false, p2]);
          }
        }
      }
      for (const [lat, letters] of CONS) {
        if (!rest.startsWith(lat)) continue;
        for (const letter of letters) {
          const p2 = pen + (RARE[lat] && RARE[lat].has(letter) ? 1 : 0);
          for (const t of bare ? [text + VIRAMA + letter, text + letter] : [text + letter]) {
            if (hasPrefix(t)) stack.push([i + lat.length, t, true, p2]);
          }
        }
      }
    }
    return [...out];
  }
  // rank: frequency, divided by 20 for each penalty point
  const rankScore = (w) => freqOf(w) / Math.pow(20, penaltyOf.get(w) || 0);

  const EN_MARGIN = 0.3, EN_MARGIN_SHORT = 1.5;
  function looksEnglish(key, bestHindi) {
    const ez = EN[key];
    if (!ez) return false;
    const hz = bestHindi ? hiZipf(bestHindi) : 0;
    return ez >= hz + (key.length <= 3 ? EN_MARGIN_SHORT : EN_MARGIN);
  }

  // Options for one typed word, best first; `why` says where option 1 came from.
  // Human romanizations (Google Dakshina lexicon, CC BY-SA 4.0): how people actually spell each Hindi word in English
  // letters, with counts. Pruned to the keys where it changes the top pick. Ranks by (count + 0.5) x frequency^0.3,
  // pooled with the dictionary's top 3; the client's rules (English kept, backchannels, chat list) still come first.
  function lexRank(key, style) {
    const raw = (window.STRIX_HI_ROMAN || {})[key];
    if (!raw) return [];
    const m = new Map();
    for (const [w, c] of raw) { const v = style ? preferred(w) : w; m.set(v, (m.get(v) || 0) + c); }
    return m;
  }


  // Options for one typed word, best first, in the shape the workbench shows: up to four Devanagari spellings and the
  // English letters as typed (first when the word stays in English). `fallback` is what the spelling rules offer and
  // `kept` the words that always stay in English (the English word list and backchannels spelled in English letters).
  function suggest(latin, fallback, kept) {
    if (!N) return fallback;  // the dictionary did not load: the rules alone, as before
    const key = latin.toLowerCase();
    if (kept.has(key)) return fallback;
    if (BACK[key]) return [BACK[key], key];
    const chat = CHAT[key] || [];
    let dict = candidates(latin).sort((a, b) => rankScore(b) - rankScore(a));
    if (!dict.length && /([bcdfghjklmnpqrstvwxz])\1/.test(latin)) {
      dict = candidates(latin.replace(/([bcdfghjklmnpqrstvwxz])\1/g, "$1")).sort((a, b) => rankScore(b) - rankScore(a));
    }
    dict = [...new Set(dict.map(preferred))];
    let roman = [];
    const counts = lexRank(key, true);
    if (counts && counts.size) {
      // the typed final vowel must be written: "bata" is not बात, "priya" is not प्रिय
      const endsBare = (w) => /[क-ह़]$|्$/.test(w);
      const score = (w) => ((counts.get(w) || 0) + 0.5) * Math.pow(freqOf(w) + 1, 0.3) * (/[ae]$/.test(key) && endsBare(w) ? 1 / 20 : 1);
      roman = [...new Set([...counts.keys(), ...dict.slice(0, 3)])].sort((a, b) => score(b) - score(a));
    }
    const rules = fallback.filter((o) => o !== key);
    const options = [...new Set([...chat, ...roman, ...dict, ...rules])].slice(0, 4);
    return !chat.length && looksEnglish(key, dict[0]) ? [key, ...options.slice(0, 3)] : [...options, key];
  }

  // English words that start with the letters typed (consum -> consumer, consumption), most common first, for the
  // English line of the suggestions. Romanized Hindi that web English lists contain (mein, thi, hui) is left out.
  const EN_KEYS = Object.keys(EN).sort();
  function englishWords(prefix, limit = 5) {
    const p = prefix.toLowerCase();
    if (!N || p.length < 2 || !/^[a-z]+$/.test(p) || CHAT[p] || BACK[p]) return [];
    // Letters that already spell a real Hindi word (ho, se, kar) get no English line: Tab would swap हो for "how".
    const hindi = candidates(p).sort((a, b) => rankScore(b) - rankScore(a));
    if (hindi.length && !looksEnglish(p, hindi[0])) return [];
    let lo = 0, hi = EN_KEYS.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (EN_KEYS[mid] < p) lo = mid + 1; else hi = mid; }
    const found = [];
    for (let i = lo; i < EN_KEYS.length && EN_KEYS[i].startsWith(p) && found.length < 400; i++) found.push(EN_KEYS[i]);
    const romanHindi = (w) => { const c = candidates(w, 1500); return c.length && Math.max(...c.map(hiZipf)) >= EN[w] - 0.5; };
    return found.sort((a, b) => (b === p) - (a === p) || EN[b] - EN[a]).filter((w) => !CHAT[w] && !BACK[w] && !romanHindi(w)).slice(0, limit);
  }

  return { suggest, englishWords };
})();
