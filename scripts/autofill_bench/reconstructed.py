#!/usr/bin/env python3
"""Reconstructed fixtures: forms whose markup is well known (checkout pages
need a session, big-name logins are JS-rendered), written down from their
shipped field names/labels. Same schema as the fetched fixture."""
import json, sys
OUT = sys.argv[1]

def F(name="", id="", type="text", tag="input", ac="", ph="", al="", label="", prev="", expected="none", **kw):
    d = dict(tag=tag, type=type, name=name, id=id, autocomplete=ac, placeholder=ph, ariaLabel=al, title="", className="",
             label=label, previousText=prev, maxLength=None, readOnly=False, disabled=False)
    d.update(kw)
    d["expected"] = expected if isinstance(expected, list) else [expected]
    return d

pages = []
def page(site, fields, form_has_password=None):
    pw = [f for f in fields if f["type"] == "password"]
    for i, f in enumerate(fields):
        f["fieldIndex"] = i; f["formIndex"] = 0; f["indexInForm"] = i
        f["formHasPassword"] = len(pw) > 0 if form_has_password is None else form_has_password
        f["passwordFieldCount"] = len(pw)
        f["textFieldCountInForm"] = len([x for x in fields if x["tag"] == "input" and x["type"] in ("text", "email", "tel", "password", "search", "url", "number")])
    pages.append({"site": site, "source": "reconstructed", "fields": fields})

page("shopify_checkout", [
    F("checkout[email]", "checkout_email", "email", ph="Email", expected="email"),
    F("checkout[shipping_address][first_name]", "checkout_shipping_address_first_name", ph="First name", expected="givenName"),
    F("checkout[shipping_address][last_name]", "checkout_shipping_address_last_name", ph="Last name", expected="familyName"),
    F("checkout[shipping_address][company]", "checkout_shipping_address_company", ph="Company (optional)", expected="organization"),
    F("checkout[shipping_address][address1]", "checkout_shipping_address_address1", ph="Address", expected="streetAddress"),
    F("checkout[shipping_address][address2]", "checkout_shipping_address_address2", ph="Apartment, suite, etc. (optional)", expected="addressLine2"),
    F("checkout[shipping_address][city]", "checkout_shipping_address_city", ph="City", expected="city"),
    F("checkout[shipping_address][country]", "checkout_shipping_address_country", "select", tag="select", label="Country/Region", expected="country", optionCount=240, optionSample=["United States", "Canada", "United Kingdom"]),
    F("checkout[shipping_address][province]", "checkout_shipping_address_province", "select", tag="select", label="State", expected="state", optionCount=60, optionSample=["Alabama", "Alaska", "Arizona"]),
    F("checkout[shipping_address][zip]", "checkout_shipping_address_zip", ph="ZIP code", expected="postalCode"),
    F("checkout[shipping_address][phone]", "checkout_shipping_address_phone", "tel", ph="Phone", expected="phone"),
])

page("stripe_checkout", [
    F("email", "email", "email", ac="email", label="Email", expected="email"),
    F("billingName", "billingName", ac="name", label="Name on card", expected="fullName"),
    F("cardNumber", "cardNumber", ac="cc-number", label="Card number", expected="none"),
    F("cardExpiry", "cardExpiry", ac="cc-exp", label="Expiration", expected="none"),
    F("cardCvc", "cardCvc", ac="cc-csc", label="CVC", expected="none"),
    F("billingCountry", "billingCountry", "select", tag="select", ac="country", label="Country or region", expected="country", optionCount=200),
    F("billingAddressLine1", "billingAddressLine1", ac="address-line1", label="Address line 1", expected="streetAddress"),
    F("billingAddressLine2", "billingAddressLine2", ac="address-line2", label="Address line 2", expected="addressLine2"),
    F("billingLocality", "billingLocality", ac="address-level2", label="City", expected="city"),
    F("billingPostalCode", "billingPostalCode", ac="postal-code", label="ZIP", expected="postalCode"),
    F("billingAdministrativeArea", "billingAdministrativeArea", "select", tag="select", ac="address-level1", label="State", expected="state", optionCount=60),
    F("phoneNumber", "phoneNumber", "tel", ac="tel", label="Phone number", expected="phone"),
])

page("amazon_add_address", [
    F("address-ui-widgets-countryCode", "address-ui-widgets-countryCode-dropdown-nativeId", "select", tag="select", label="Country/Region", expected="country", optionCount=250),
    F("address-ui-widgets-enterAddressFullName", "address-ui-widgets-enterAddressFullName", label="Full name (First and Last name)", expected="fullName"),
    F("address-ui-widgets-enterAddressPhoneNumber", "address-ui-widgets-enterAddressPhoneNumber", "tel", label="Phone number", expected="phone"),
    F("address-ui-widgets-enterAddressLine1", "address-ui-widgets-enterAddressLine1", ph="Street address or P.O. Box", label="Address", expected="streetAddress"),
    F("address-ui-widgets-enterAddressLine2", "address-ui-widgets-enterAddressLine2", ph="Apt, suite, unit, building, floor, etc.", expected="addressLine2"),
    F("address-ui-widgets-enterAddressCity", "address-ui-widgets-enterAddressCity", label="City", expected="city"),
    F("address-ui-widgets-enterAddressStateOrRegion", "address-ui-widgets-enterAddressStateOrRegion", "select", tag="select", label="State", expected="state", optionCount=60),
    F("address-ui-widgets-enterAddressPostalCode", "address-ui-widgets-enterAddressPostalCode", label="ZIP Code", expected="postalCode"),
    F("address-ui-widgets-addressInstructions", "address-ui-widgets-addressInstructions", tag="textarea", type="textarea", label="Delivery instructions (optional)", expected="none"),
])

page("amazon_signin", [
    F("email", "ap_email", "email", label="Email or mobile phone number", expected=["email", "username"]),
    F("password", "ap_password", "password", label="Password", expected="password"),
])
page("google_identifier", [
    F("identifier", "identifierId", "email", ac="username", al="Email or phone", expected=["email", "username"]),
])
page("google_password", [
    F("Passwd", "", "password", ac="current-password", al="Enter your password", expected="password"),
])
page("apple_id", [
    F("", "account_name_text_field", ac="username", al="Apple Account", ph="Email or Phone Number", expected=["username", "email"]),
    F("", "password_text_field", "password", ac="current-password", al="Password", expected="password"),
])
page("microsoft_login", [
    F("loginfmt", "i0116", "email", ac="username", ph="Email, phone, or Skype", al="Enter your email, phone, or Skype.", expected=["email", "username"]),
])
page("microsoft_password", [
    F("passwd", "i0118", "password", ac="current-password", ph="Password", al="Enter the password for you@example.com", expected="password"),
])
page("x_login", [
    F("text", "", "text", ac="username", label="Phone, email, or username", expected=["username", "email", "phone"]),
    F("password", "", "password", ac="current-password", label="Password", expected="password"),
])
page("reddit_login", [
    F("username", "login-username", ac="username", label="Email or username", expected=["username", "email"]),
    F("password", "login-password", "password", ac="current-password", label="Password", expected="password"),
])
page("instagram_login", [
    F("username", "", ac="username", al="Phone number, username, or email", expected=["username", "email", "phone"]),
    F("password", "", "password", ac="current-password", al="Password", expected="password"),
])
page("github_login", [
    F("login", "login_field", ac="username", label="Username or email address", expected=["username", "email"]),
    F("password", "password", "password", ac="current-password", label="Password", expected="password"),
])
page("github_signup", [
    F("user[email]", "email", "email", ac="email", label="Email", expected="email"),
    F("user[password]", "password", "password", ac="new-password", label="Password", expected="newPassword"),
    F("user[login]", "login", ac="username", label="Username", expected="username"),
])
page("yahoo_login", [
    F("username", "login-username", ac="username", ph="Username, email, or mobile", expected=["username", "email", "phone"]),
])
page("paypal_login", [
    F("login_email", "email", "email", ac="username", ph="Email or mobile number", expected=["email", "username"]),
    F("login_password", "password", "password", ac="current-password", ph="Password", expected="password"),
])
page("ebay_signin", [
    F("userid", "userid", ac="username", ph="Email or username", expected=["username", "email"]),
    F("pass", "pass", "password", ac="current-password", ph="Password", expected="password"),
])
page("etsy_signin", [
    F("email", "join_neu_email_field", "email", ac="email", label="Email address", expected="email"),
    F("password", "join_neu_password_field", "password", ac="current-password", label="Password", expected="password"),
])
page("dropbox_login", [
    F("login_email", "", "email", ac="email", ph="Email", expected="email"),
    F("login_password", "", "password", ac="current-password", ph="Password", expected="password"),
])
page("discord_login", [
    F("email", "uid_7", ac="username", label="Email or Phone Number", expected=["email", "username", "phone"]),
    F("password", "uid_9", "password", ac="current-password", label="Password", expected="password"),
])
page("slack_workspace", [
    F("domain", "domain", ac="off", ph="your-workspace-url", label="Enter your workspace's Slack URL", expected="none"),
])
page("zalando_login_de", [
    F("login.email", "login.email", "email", ac="username", label="E-Mail-Adresse", expected="email"),
    F("login.secret", "login.secret", "password", ac="current-password", label="Passwort", expected="password"),
])
page("french_checkout", [
    F("prenom", "prenom", label="Prénom", expected="givenName"),
    F("nom", "nom", label="Nom", expected="familyName"),
    F("courriel", "courriel", "email", label="Adresse e-mail", expected="email"),
    F("telephone", "telephone", "tel", label="Téléphone", expected="phone"),
    F("adresse", "adresse", label="Adresse", expected="streetAddress"),
    F("complement", "complement", label="Complément d'adresse", expected="addressLine2"),
    F("code_postal", "code_postal", label="Code postal", expected="postalCode"),
    F("ville", "ville", label="Ville", expected="city"),
    F("pays", "pays", "select", tag="select", label="Pays", expected="country", optionCount=200),
])
page("spanish_registro", [
    F("nombre", "nombre", label="Nombre", expected="givenName"),
    F("apellidos", "apellidos", label="Apellidos", expected="familyName"),
    F("correo", "correo", "email", label="Correo electrónico", expected="email"),
    F("telefono", "telefono", "tel", label="Teléfono", expected="phone"),
    F("direccion", "direccion", label="Dirección", expected="streetAddress"),
    F("codigo_postal", "cp", label="Código postal", expected="postalCode"),
    F("ciudad", "ciudad", label="Ciudad", expected="city"),
    F("provincia", "provincia", label="Provincia", expected="state"),
    F("contrasena", "contrasena", "password", label="Contraseña", expected="newPassword"),
    F("contrasena2", "contrasena2", "password", label="Repetir contraseña", expected="newPassword"),
])
page("german_adresse", [
    F("vorname", "vorname", label="Vorname", expected="givenName"),
    F("nachname", "nachname", label="Nachname", expected="familyName"),
    F("firma", "firma", label="Firma (optional)", expected="organization"),
    F("strasse", "strasse", label="Straße und Hausnummer", expected="streetAddress"),
    F("plz", "plz", label="PLZ", expected="postalCode"),
    F("ort", "ort", label="Ort", expected="city"),
    F("land", "land", "select", tag="select", label="Land", expected="country", optionCount=50),
    F("telefon", "telefon", "tel", label="Telefonnummer", expected="phone"),
    F("email", "email", "email", label="E-Mail", expected="email"),
])
page("generic_signup_camelcase", [
    F("firstName", "firstName", ph="First name", expected="givenName"),
    F("lastName", "lastName", ph="Last name", expected="familyName"),
    F("emailAddress", "emailAddress", ph="you@example.com", expected="email"),
    F("phoneNumber", "phoneNumber", ph="(555) 555-5555", expected="phone"),
    F("companyName", "companyName", ph="Company", expected="organization"),
    F("newPassword", "newPassword", "password", ph="Create a password", expected="newPassword"),
    F("confirmPassword", "confirmPassword", "password", ph="Confirm password", expected="newPassword"),
    F("promoCode", "promoCode", ph="Promo code", expected="none"),
    F("otp", "otp", ph="6-digit code", expected="none"),
    F("cardName", "cc-name", ac="cc-name", ph="Name on card", expected="fullName"),
    F("cardNumber", "cc-number", ac="cc-number", ph="Card number", expected="none"),
    F("securityAnswer", "securityAnswer", ph="What was the name of your first pet?", expected="none"),
    F("website", "website", "url", ph="https://", expected="none"),
    F("dateOfBirth", "dob", ph="MM/DD/YYYY", expected="none"),
    F("ssn", "ssn", ph="Social security number", expected="none"),
    F("captcha", "captcha", ph="Type the characters", expected="none"),
])
page("aria_only_login", [
    F("", "u1", al="Username", expected="username"),
    F("", "p1", "password", al="Password", expected="password"),
])
page("bare_login_no_hints", [
    F("", "field-1", expected="username"),
    F("", "field-2", "password", expected="password"),
])
page("newsletter_only", [
    F("", "nl", "email", ph="Subscribe to our newsletter", expected="email"),
])
page("comment_form", [
    F("author", "author", label="Name", expected="fullName"),
    F("email", "email", "email", label="Email", expected="email"),
    F("url", "url", "url", label="Website", expected="none"),
    F("comment", "comment", tag="textarea", type="textarea", label="Comment", expected="none"),
])
page("search_negatives", [
    F("q", "q", "search", ph="Search", expected="none"),
    F("query", "", ph="Search by name, email, or phone", expected="none"),
    F("filter", "", ph="Filter users by username", expected="none"),
    F("location", "", ph="Enter a city or zip code", expected="none"),
])

json.dump(pages, open(OUT, "w"), indent=1, ensure_ascii=False)
print(len(pages), "pages", sum(len(p["fields"]) for p in pages), "fields")
