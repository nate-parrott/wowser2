#!/usr/bin/env python3
"""Attach hand-annotated expected kinds to the extracted fixture and emit the
benchmark JSON consumed by AutofillClassifierTests.

`expected` is a list of acceptable kinds ("none" = the classifier must not
offer autofill for this field). Multiple entries mark genuinely ambiguous
fields (e.g. "Email or username" login identifiers)."""
import json, sys

RAW, OUT = sys.argv[1], sys.argv[2]

A = {}
def ann(site, mapping):
    A[site] = {int(k): (v if isinstance(v, list) else [v]) for k, v in mapping.items()}

ann("accounts_craigslist_org_login", {5: ["username", "email"], 6: "password", 11: "email"})
ann("automationexercise_com_login", {1: "email", 2: "password", 4: "fullName", 5: "email", 8: "email"})
ann("demo_applitools_com_", {0: "username", 1: "password"})
ann("demo_guru99_com_V4_", {0: "username", 1: "password"})
ann("demo_guru99_com_insurance_v1_index_php", {0: "email", 1: "password"})
ann("demo_guru99_com_insurance_v1_register_php", {2: "none", 3: "givenName", 4: "familyName", 5: "phone", 6: "none", 7: "none", 8: "none", 11: "none", 12: "none", 13: "streetAddress", 14: "city", 15: ["state", "none"], 16: "postalCode", 17: "email", 18: "newPassword", 19: "newPassword"})
ann("demo_guru99_com_test_login_html", {0: "email", 1: "password"})
ann("demo_guru99_com_test_newtours_", {1: "username", 2: "password"})
ann("demo_guru99_com_test_newtours_register_php", {1: "givenName", 2: "familyName", 3: "phone", 4: ["email", "username"], 5: "streetAddress", 6: "city", 7: "state", 8: "postalCode", 9: "country", 10: ["username", "email"], 11: "newPassword", 12: "newPassword"})
ann("dribbble_com_session_new", {0: "email", 1: ["username", "email"]})
ann("ecommerce_playground_lambdatest_io_index_php_route_account_login", {2: "none", 5: "none", 6: "email", 7: "password"})
ann("ecommerce_playground_lambdatest_io_index_php_route_account_register", {2: "none", 5: "none", 7: "givenName", 8: "familyName", 9: "email", 10: "phone", 11: "newPassword", 12: "newPassword"})
ann("en_wikipedia_org_w_index_php_title_Special_CreateAccount", {1: "none", 8: "username", 9: "newPassword", 10: "newPassword", 11: "email", 17: "none"})
ann("en_wikipedia_org_w_index_php_title_Special_UserLogin", {1: "none", 8: "username", 9: "password", 17: "none"})
ann("formy_project_herokuapp_com_form", {0: "givenName", 1: "familyName", 2: "none", 9: "none", 10: "none"})
ann("forums_craigslist_org_", {1: "none", 3: "none"})
ann("id_heroku_com_login", {1: "email", 2: "password"})
ann("lobste_rs_login", {1: ["username", "email"], 2: "password"})
ann("mailchimp_com_", {13: "none", 14: "none", 17: "none", 18: "none", 19: "none"})
ann("news_ycombinator_com_login", {0: "username", 1: "password", 4: "username", 5: "newPassword"})
ann("parabank_parasoft_com_parabank_register_htm", {0: "username", 1: "password", 3: "givenName", 4: "familyName", 5: "streetAddress", 6: "city", 7: "state", 8: "postalCode", 9: "phone", 10: "none", 11: "username", 12: "newPassword", 13: "newPassword"})
ann("petstore_octoperf_com_actions_Account_action_newAccountForm_", {0: "none", 4: "username", 5: ["none", "newPassword", "password"], 6: ["none", "newPassword", "password"], 7: "givenName", 8: "familyName", 9: "email", 10: "phone", 11: "streetAddress", 12: "addressLine2", 13: "city", 14: "state", 15: "postalCode", 16: "country", 17: "none", 18: "none"})
ann("petstore_octoperf_com_actions_Account_action_signonForm_", {0: "none", 4: "username", 5: "password"})
ann("practice_expandtesting_com_register", {0: "username", 1: "newPassword", 2: "newPassword"})
ann("pypi_org_account_login_", {0: "none", 1: "none", 3: "username", 5: "password"})
ann("pypi_org_account_register_", {0: "none", 1: "none", 3: "fullName", 4: "email", 5: "none", 6: "username", 8: "newPassword", 9: "newPassword"})
ann("rubygems_org_sign_in", {0: "none", 2: ["username", "email"], 3: "password"})
ann("rubygems_org_sign_up", {0: "none", 2: "fullName", 3: "email", 4: "username", 5: "newPassword"})
ann("stackoverflow_com_users_login", {0: "none", 3: "email", 4: "password"})
ann("testpages_eviltester_com_styled_basic_html_form_test_html", {274: "username", 275: "password", 276: "none", 285: "none", 286: "none", 290: "none"})
ann("the_internet_herokuapp_com_login", {0: "username", 1: "password"})
ann("ultimateqa_com_automation", {0: "none"})
ann("ultimateqa_com_filling_out_forms_", {0: "none", 1: "fullName", 2: "none", 6: "fullName", 7: "none", 9: "none"})
ann("vercel_com_login", {0: "email"})
ann("www_airbnb_com_login", {0: ["phone", "email", "username"]})
ann("www_bankofamerica_com_", {0: "none", 1: "phone", 2: "email", 3: "phone"})
ann("www_bbc_com_signin", {0: ["username", "email"]})
ann("www_bol_com_nl_nl_account_inloggen_", {4: "none"})
ann("www_chase_com_", {0: "username", 1: "password"})
ann("www_costco_com_logon_instructions", {13: "none"})
ann("www_coursera_org_login", {0: "none"})
ann("www_facebook_com_login", {2: ["email", "username"], 3: "password"})
ann("www_geico_com_", {0: "state"})
ann("www_globalsqa_com_demo_site_", {0: "none"})
ann("www_instacart_com_login", {0: "email"})
ann("www_last_fm_login", {0: "none", 1: "none", 4: ["username", "email"], 5: "password"})
ann("www_lemonde_fr_", {0: "none"})
ann("www_linkedin_com_login", {0: ["email", "username"], 1: "password", 3: ["email", "username"], 4: "password"})
ann("www_llbean_com_", {0: "email", 1: "email", 2: "none", 3: "none", 4: "email"})
ann("www_mercadolibre_com_ar_", {0: "none"})
ann("www_namecheap_com_myaccount_login_", {6: "username", 7: "password", 9: "none", 10: "username", 11: "password", 14: "email"})
ann("www_netflix_com_login", {0: ["email", "username"], 1: "password", 2: "none"})
ann("www_otto_de_", {0: "none"})
ann("www_progressive_com_", {2: "postalCode", 12: ["state", "none"], 14: "postalCode", 25: ["state", "none"], 36: ["state", "none"], 39: "postalCode", 49: ["state", "none"], 60: ["state", "none"], 61: "none"})
ann("www_selenium_dev_selenium_web_web_form_html", {0: "none", 1: "password", 2: "none", 3: "none", 4: "none", 5: "none", 6: "none", 13: "none"})
ann("www_spotify_com_us_signup", {0: ["email", "username"]})
ann("www_staples_com_", {0: "none"})
ann("www_strava_com_login", {1: "email", 2: ["country", "none"], 4: "email", 5: ["country", "none"]})
ann("www_strava_com_register", {1: "email", 2: ["country", "none"], 3: "email", 4: ["country", "none"]})
ann("www_techlistic_com_p_selenium_practice_form_html", {0: "none", 2: "givenName", 3: "familyName", 13: "none", 19: "none", 20: "none"})
ann("www_todoist_com_users_showlogin", {0: "none"})
ann("www_tumblr_com_login", {0: "email", 1: "password", 2: "none"})
ann("www_tutorialspoint_com_index_htm", {0: "none", 1: "none"})
ann("www_uber_com_us_en_ride_", {i: "none" for i in range(3, 27)})
ann("www_usps_com_", {i: "none" for i in [0, 2, 4, 6, 8, 10, 12, 14, 15]})
ann("www_wellsfargo_com_", {0: "none", 1: "username", 2: "password", 14: "none", 15: "none"})
ann("www_wordpress_com_log_in", {0: ["username", "email"], 1: "password"})
ann("www_wordpress_org_support_", {0: "none", 1: "none", 2: "none"})
ann("www_zappos_com_", {0: "none", 1: "email"})

raw = json.load(open(RAW))
out = []
missing = 0
for page in raw:
    site = page["site"]
    ann_map = A.get(site)
    if ann_map is None:
        print("UNANNOTATED PAGE", site); continue
    fields = []
    for f in page["fields"]:
        exp = ann_map.get(f["fieldIndex"])
        if exp is None:
            missing += 1
            print("MISSING", site, f["fieldIndex"]); continue
        f = dict(f); f["expected"] = exp
        fields.append(f)
    out.append({"site": site, "source": "fetched", "fields": fields})
print("annotated pages:", len(out), "fields:", sum(len(p["fields"]) for p in out), "missing:", missing)
json.dump(out, open(OUT, "w"), indent=1, ensure_ascii=False)
