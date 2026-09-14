/* sample.js — レイアウト検討用のダミー。文字数の当たりだけ合わせてある */
export const SAMPLE = {
  title: "サンプル（中身はダミー）",
  demo: true,
  duration: 90,
  lanes: ["ナレーション", "人物A", "人物B"],
  baseRate: 7.0,
  limitRate: 9.0,
  blocks: [
    { lane: 0, kind: "NARR", t: 0, cells: [{
      dur: 18,
      en: "In this video we're looking at one thing: what to do when someone twists your words mid-conversation, and how to answer without losing your composure. He does three things, and none of them require special training.",
      ja: "この動画で見ていくのは、会話の途中で相手に言葉をねじ曲げられたとき、どうすれば落ち着いたまま切り返せるのか、という一点です。彼がやったことは、実のところ三つしかありません。しかもどれも特別な訓練はいらない。今日の夕方の会議からそのまま使えるものです。",
    }]},
    { lane: 1, kind: "LIP", t: 18, cells: [
      { dur: 3.5, en: "So what you're saying is, essentially, that—", ja: "つまりあなたがおっしゃりたいのは、要するにこういうことですよね" },
      { dur: 4.0, en: "—women earn less than men, and that's discrimination.", ja: "女性の収入が男性より少ないのは、差別だと" },
      { dur: 3.5, en: "Is that a fair characterization?", ja: "そういう理解でよろしいんですか" },
    ]},
    { lane: 0, kind: "NARR", t: 30, cells: [{
      dur: 22,
      en: "When someone paraphrases you unfairly, most people rush to deny it. But the faster you deny it, the less composed you look. He did the opposite — he let the summary land first.",
      ja: "自分の発言を勝手に言い換えられると、ほとんどの人はその場で否定しにかかります。ですが急いで否定するほど、見ている側には余裕がないように映ってしまう。彼が最初に選んだのは、まったく逆の動きでした。相手の要約を、いったん最後まで受け取ったんです。",
    }]},
    { lane: 2, kind: "LIP", t: 52, cells: [
      { dur: 5.0, en: "That's not what I said, actually.", ja: "その要約は、私が実際に言ったこととは違います" },
      { dur: 6.0, en: "Let me take this in order. The premise is missing something important.", ja: "順番に説明させてください。まず、前提の部分がまるごと抜け落ちています" },
    ]},
    { lane: 0, kind: "NARR", t: 64, cells: [{
      dur: 26,
      en: "From here we'll break the exchange down piece by piece. Where his eyes go, how he uses pauses, and how he hands the question back instead of returning it. None of this takes talent.",
      ja: "ここからは、実際のやり取りを一つずつ分解していきます。目の動き、間の取り方、そして質問をそのまま返さずに一度預けるやり方。どれも特別な才能はいりません。必要なのは、その場で何が起きているのかを正確に見ていること、それだけです。この三つが揃った瞬間に、会話の主導権は静かに入れ替わります。",
    }]},
  ],
};
