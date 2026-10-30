// 사이트 설정 — 값을 채우는 곳은 여기 한 곳뿐이에요. 비워 두면 안전하게 동작합니다.
// Edit only this file. Leave a value empty and the site degrades safely.
window.BUNI_SITE_CONFIG = {
  // Stripe 결제 링크(https만 인정). 비면 버튼이 '준비 중'으로 비활성화돼요.
  // Stripe Payment Links (https only). Empty → the button shows "Coming soon" and is disabled.
  stripeLinks: {
    monthly:  '',   // 월 $3 / $3 per month
    yearly:   '',   // 연 $24 / $24 per year
    lifetime: '',   // 평생 $49 / $49 one-time
    packs: { sakura: '', space: '', cafe: '' }
  },
  // Plausible 분석: 도메인을 넣으면 그때부터 스크립트를 불러와요. 비면 아무것도 불러오지 않아요.
  // Plausible: set your site domain to load the script. Empty → nothing is loaded.
  plausibleDomain: '',            // 예: 'example.com'
  plausibleScript: 'https://plausible.io/js/script.js'
};

(function(){
  var c = window.BUNI_SITE_CONFIG;
  if(!c || !/^[a-z0-9.-]+\.[a-z]{2,}$/i.test(c.plausibleDomain || '')) return;
  var s = document.createElement('script');
  s.defer = true;
  s.setAttribute('data-domain', c.plausibleDomain);
  s.src = c.plausibleScript;
  document.head.appendChild(s);
})();
