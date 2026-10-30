"""
Pro 상태·체험·게이트 시험 — python3 tests/test_pro.py   (시험 전용 키 쌍 사용)
"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'windows'))
import buni_license as lic  # noqa: E402
import buni_pro as pro      # noqa: E402

TEST_ONLY_SEED = bytes.fromhex('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60')
PUB = lic.public_from_seed(TEST_ONLY_SEED)
T0 = 1_800_000_000
DAY = 86400


class Clock:
    def __init__(self, t):
        self.t = t

    def __call__(self):
        return self.t


class ProStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.clock = Clock(T0)

    def tearDown(self):
        self.tmp.cleanup()

    def store(self):
        return pro.ProStore(self.dir, pubkey=PUB, clock=self.clock)

    def test_constants(self):
        self.assertEqual(pro.TRIAL_DAYS_EXISTING, 30)
        self.assertEqual(pro.TRIAL_DAYS_NEW, 14)

    def test_new_user_gets_14_days_then_locks(self):
        s = self.store()
        self.assertFalse(s.was_existing_user)
        st = s.status()
        self.assertEqual((st.kind, st.days_left), (pro.TRIAL, 14))
        self.assertTrue(s.can('squad_parallel'))
        self.clock.t = T0 + 13 * DAY + 100
        self.assertEqual(s.status().kind, pro.TRIAL)
        self.assertEqual(s.status().days_left, 1)
        self.clock.t = T0 + 14 * DAY + 1
        self.assertEqual(s.status().kind, pro.EXPIRED)
        self.assertFalse(s.can('squad_parallel'))

    def test_existing_user_gets_30_days(self):
        (self.dir / 'shop.json').write_text('{}')
        s = self.store()
        self.assertTrue(s.was_existing_user)
        self.assertEqual(s.status().days_left, 30)
        self.clock.t = T0 + 29 * DAY
        self.assertEqual(s.status().kind, pro.TRIAL)
        self.clock.t = T0 + 30 * DAY + 1
        self.assertEqual(s.status().kind, pro.EXPIRED)

    def test_trial_start_persists_across_restart(self):
        self.store()
        self.clock.t = T0 + 5 * DAY
        # 두 번째 실행 때 shop.json 이 생겨 있어도 체험 시작·일수는 처음 기록 그대로
        (self.dir / 'shop.json').write_text('{}')
        s = self.store()
        self.assertEqual(s.status().days_left, 9)
        self.assertFalse(s.was_existing_user)

    def test_subscribed_overrides_expired_trial(self):
        s = self.store()
        self.clock.t = T0 + 40 * DAY
        self.assertEqual(s.status().kind, pro.EXPIRED)
        ok, _ = s.activate(lic.make_key(TEST_ONLY_SEED, 'lifetime'))
        self.assertTrue(ok)
        st = s.status()
        self.assertEqual((st.kind, st.plan), (pro.SUBSCRIBED, 'lifetime'))
        for f in pro.FEATURES:
            self.assertTrue(s.can(f), f)
        # 재시작해도 유지
        self.assertEqual(self.store().status().kind, pro.SUBSCRIBED)

    def test_expired_subscription_falls_back_to_free(self):
        s = self.store()
        key = lic.make_key(TEST_ONLY_SEED, 'monthly', '20270201')
        self.assertTrue(s.activate(key)[0])
        self.assertEqual(s.status().kind, pro.SUBSCRIBED)
        self.clock.t = T0 + 60 * DAY
        self.assertEqual(s.status().kind, pro.EXPIRED)

    def test_bad_keys_are_not_activated(self):
        s = self.store()
        self.assertEqual(s.activate('nope'), (False, 'format'))
        self.assertEqual(s.activate(lic.make_key(bytes(32), 'lifetime')), (False, 'signature'))
        self.assertEqual(s.activate(lic.make_key(TEST_ONLY_SEED, 'monthly', '20200101')), (False, 'expired'))
        self.assertEqual(s.status().kind, pro.TRIAL)

    def test_free_features_never_locked(self):
        s = self.store()
        self.clock.t = T0 + 100 * DAY
        self.assertEqual(s.status().kind, pro.EXPIRED)
        for f in ('session_panel', 'status_display', 'chat', 'squad_single'):
            self.assertTrue(s.can(f), f)
        self.assertTrue(s.item_unlocked('rabbit'))          # 기존 캐릭터는 팩 밖 → 무료
        self.assertTrue(s.item_unlocked('theme_default'))
        for f in pro.FEATURES:
            self.assertFalse(s.can(f), f)

    def test_pack_unlock(self):
        s = self.store()
        self.clock.t = T0 + 100 * DAY
        self.assertFalse(s.item_unlocked('theme_sakura'))
        s.activate(lic.make_key(TEST_ONLY_SEED, 'pack:sakura'))
        self.assertTrue(s.item_unlocked('theme_sakura'))
        self.assertFalse(s.item_unlocked('theme_space'))
        self.assertFalse(s.item_unlocked('theme_midnight'))   # Pro 전용 팩은 팩 키로 안 열린다
        self.assertEqual(s.status().kind, pro.EXPIRED)         # 팩 키는 Pro 가 아니다

    def test_pack_discount(self):
        self.assertEqual(pro.pack_price_cents('sakura', False), 299)
        self.assertEqual(pro.pack_price_cents('sakura', True), 209)   # 299 * 0.7 = 209.3
        self.assertEqual(pro.pack_price_cents('space', True), 244)    # 349 * 0.7 = 244.3
        self.assertIsNone(pro.pack_price_cents('pro_colors', True))   # Pro 전용은 따로 안 판다
        self.assertIsNone(pro.pack_price_cents('nope', False))
        self.assertEqual(pro.format_usd(209), '$2.09')

    def test_pack_discount_uses_subscription_not_trial(self):
        s = self.store()
        self.assertEqual(s.pack_price_cents('cafe'), 399)             # 체험 중엔 할인 없음
        s.activate(lic.make_key(TEST_ONLY_SEED, 'yearly', '20271231'))
        self.assertEqual(s.pack_price_cents('cafe'), 279)

    def test_cloud_sync_policy_keeps_data(self):
        s = self.store()
        self.assertEqual(s.cloud_sync_policy(False), 'allow')         # 체험 중
        self.clock.t = T0 + 100 * DAY
        self.assertEqual(s.cloud_sync_policy(True), 'pause_keep_data')
        self.assertEqual(s.cloud_sync_policy(False), 'blocked')

    def test_corrupt_pro_json_restarts_trial(self):
        (self.dir / 'pro.json').write_text('{broken')
        self.assertEqual(self.store().status().kind, pro.TRIAL)

    def test_messages(self):
        ko, en = pro.lock_message('squad_schedule')
        self.assertIn('Pro', ko)
        self.assertIn('Pro', en)
        self.assertIn('체험 중', pro.status_text(pro.ProStatus(pro.TRIAL, 3))[0])


class CheckoutTests(unittest.TestCase):
    ENV = ['BUNI_STRIPE_LINK_MONTHLY', 'BUNI_STRIPE_LINK_YEARLY',
           'BUNI_STRIPE_LINK_LIFETIME', 'BUNI_STRIPE_LINK_PACK_SAKURA']

    def setUp(self):
        self.saved = {k: os.environ.pop(k, None) for k in self.ENV}

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def test_missing_link_is_disabled_coming_soon(self):
        for plan in ('monthly', 'yearly', 'lifetime', 'pack:sakura', 'bogus'):
            enabled, link, label = pro.checkout_button(plan, config={})
            self.assertFalse(enabled)
            self.assertIsNone(link)
            self.assertEqual(label[0], '준비 중')

    def test_env_beats_config(self):
        os.environ['BUNI_STRIPE_LINK_MONTHLY'] = 'https://buy.stripe.com/env'
        cfg = {'stripe_links': {'monthly': 'https://buy.stripe.com/cfg', 'yearly': 'https://buy.stripe.com/y'}}
        self.assertEqual(pro.checkout_link('monthly', cfg), 'https://buy.stripe.com/env')
        self.assertEqual(pro.checkout_link('yearly', cfg), 'https://buy.stripe.com/y')
        self.assertTrue(pro.checkout_button('yearly', cfg)[0])

    def test_non_https_or_garbage_ignored(self):
        os.environ['BUNI_STRIPE_LINK_MONTHLY'] = 'javascript:alert(1)'
        cfg = {'stripe_links': {'yearly': 'http://insecure', 'lifetime': 5, 'pack:sakura': 'https://x y'}}
        for plan in ('monthly', 'yearly', 'lifetime', 'pack:sakura'):
            self.assertIsNone(pro.checkout_link(plan, cfg))
        self.assertIsNone(pro.checkout_link('monthly', {'stripe_links': 'bad'}))


if __name__ == '__main__':
    unittest.main()
