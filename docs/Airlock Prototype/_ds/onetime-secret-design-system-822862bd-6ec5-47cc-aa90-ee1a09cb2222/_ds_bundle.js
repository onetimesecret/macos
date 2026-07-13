/* @ds-bundle: {"format":3,"namespace":"OnetimeSecretDesignSystem_822862","components":[],"sourceHashes":{"ui_kits/marketing-site/Hero.jsx":"1d14b86ed94c","ui_kits/marketing-site/MarketingNav.jsx":"e78b36b33cb9","ui_kits/marketing-site/Sections.jsx":"bbf994357c9a","ui_kits/marketing-site/app.jsx":"82570ee9cb87","ui_kits/secret-app/Create.jsx":"422192994c0c","ui_kits/secret-app/Reveal.jsx":"cdd656bdca6c","ui_kits/secret-app/Share.jsx":"58027b381e8c","ui_kits/secret-app/app.jsx":"01ad5fdfaac1"},"inlinedExternals":[],"unexposedExports":[]} */

(() => {

const __ds_ns = (window.OnetimeSecretDesignSystem_822862 = window.OnetimeSecretDesignSystem_822862 || {});

const __ds_scope = {};

(__ds_ns.__errors = __ds_ns.__errors || []);

// ui_kits/marketing-site/Hero.jsx
try { (() => {
const {
  useState
} = React;
const Hero = () => {
  const [val, setVal] = useState("");
  return /*#__PURE__*/React.createElement("section", {
    className: "ots-hero",
    "aria-labelledby": "hero-heading"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-hero-glow a",
    "aria-hidden": "true"
  }), /*#__PURE__*/React.createElement("div", {
    className: "ots-hero-glow b",
    "aria-hidden": "true"
  }), /*#__PURE__*/React.createElement("div", {
    className: "ots-hero-inner"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-hero-badge"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-dot"
  }), "Now with regional data residency"), /*#__PURE__*/React.createElement("h1", {
    id: "hero-heading",
    className: "ots-hero-h1"
  }, /*#__PURE__*/React.createElement("span", null, "Keep sensitive info"), /*#__PURE__*/React.createElement("span", {
    className: "ots-gradient-text"
  }, " out of ", /*#__PURE__*/React.createElement("em", null, "your"), " inboxes.")), /*#__PURE__*/React.createElement("p", {
    className: "ots-hero-sub"
  }, "Share passwords, API keys, and private messages through links that self-destruct after one view."), /*#__PURE__*/React.createElement("div", {
    className: "ots-secret-form",
    role: "region",
    "aria-label": "Create a secret"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-region-row"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-region-label"
  }, "Store in"), /*#__PURE__*/React.createElement("button", {
    className: "ots-region-chip active"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-dot small"
  }), "\uD83C\uDDEA\uD83C\uDDFA EU"), /*#__PURE__*/React.createElement("button", {
    className: "ots-region-chip"
  }, "\uD83C\uDDFA\uD83C\uDDF8 US"), /*#__PURE__*/React.createElement("button", {
    className: "ots-region-chip"
  }, "\uD83C\uDDE8\uD83C\uDDE6 CA"), /*#__PURE__*/React.createElement("button", {
    className: "ots-region-chip"
  }, "\uD83C\uDDF3\uD83C\uDDFF NZ")), /*#__PURE__*/React.createElement("textarea", {
    className: "ots-secret-textarea",
    placeholder: "Paste the secret you'd like to share in the EU\u2026",
    value: val,
    onChange: e => setVal(e.target.value)
  }), /*#__PURE__*/React.createElement("div", {
    className: "ots-secret-foot"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-secret-meta"
  }, /*#__PURE__*/React.createElement("span", null, "Optional passphrase"), /*#__PURE__*/React.createElement("span", null, "\xB7"), /*#__PURE__*/React.createElement("span", null, "Expires in 7 days"), /*#__PURE__*/React.createElement("span", null, "\xB7"), /*#__PURE__*/React.createElement("span", null, "Burn before reading")), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-primary ots-btn-md"
  }, "Create a secret link"))), /*#__PURE__*/React.createElement("ul", {
    className: "ots-compliance",
    "aria-label": "Compliance"
  }, /*#__PURE__*/React.createElement("li", null, "SOC 2 Type II"), /*#__PURE__*/React.createElement("li", null, "GDPR-ready"), /*#__PURE__*/React.createElement("li", null, "HIPAA-adjacent workflows"), /*#__PURE__*/React.createElement("li", null, "Open source"), /*#__PURE__*/React.createElement("li", null, "Operating since 2011"))));
};
window.Hero = Hero;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/marketing-site/Hero.jsx", error: String((e && e.message) || e) }); }

// ui_kits/marketing-site/MarketingNav.jsx
try { (() => {
// Nav component for marketing site
const MarketingNav = () => /*#__PURE__*/React.createElement("header", {
  className: "ots-nav"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-nav-inner"
}, /*#__PURE__*/React.createElement("a", {
  href: "#",
  className: "ots-brand"
}, /*#__PURE__*/React.createElement("img", {
  src: "../../assets/onetime-logo-v3-md.png",
  alt: "",
  width: "36",
  height: "36"
}), /*#__PURE__*/React.createElement("span", null, "Onetime Secret")), /*#__PURE__*/React.createElement("nav", {
  className: "ots-nav-links"
}, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Home"), /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "About"), /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Pricing"), /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Docs")), /*#__PURE__*/React.createElement("div", {
  className: "ots-nav-auth"
}, /*#__PURE__*/React.createElement("a", {
  href: "#",
  className: "ots-nav-signin"
}, "Sign in"), /*#__PURE__*/React.createElement("a", {
  href: "#",
  className: "ots-btn ots-btn-primary ots-btn-sm"
}, "Sign up \u2192"))));
window.MarketingNav = MarketingNav;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/marketing-site/MarketingNav.jsx", error: String((e && e.message) || e) }); }

// ui_kits/marketing-site/Sections.jsx
try { (() => {
const FeatureCard = ({
  icon,
  title,
  desc,
  span,
  comp
}) => /*#__PURE__*/React.createElement("div", {
  className: `ots-feat-card${span ? " span2" : ""}`
}, /*#__PURE__*/React.createElement("div", {
  className: `ots-feat-icon${comp ? " comp" : ""}`
}, /*#__PURE__*/React.createElement("i", {
  "data-lucide": icon,
  width: "22",
  height: "22"
})), /*#__PURE__*/React.createElement("h3", null, title), /*#__PURE__*/React.createElement("p", null, desc));
const Features = () => /*#__PURE__*/React.createElement("section", {
  className: "ots-section"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-container"
}, /*#__PURE__*/React.createElement("p", {
  className: "ots-section-label"
}, "What it does"), /*#__PURE__*/React.createElement("h2", {
  className: "ots-section-h2"
}, "Mechanism, not marketing."), /*#__PURE__*/React.createElement("p", {
  className: "ots-section-sub"
}, "Every feature exists to answer a specific security question. No abstractions."), /*#__PURE__*/React.createElement("div", {
  className: "ots-bento"
}, /*#__PURE__*/React.createElement(FeatureCard, {
  icon: "lock",
  title: "End-to-end encryption",
  desc: "AES-256 with bcrypt-hashed passphrases. Keys never leave the jurisdiction you chose.",
  span: true
}), /*#__PURE__*/React.createElement(FeatureCard, {
  icon: "clock",
  title: "Time-bound",
  desc: "Expire from minutes to 14 days."
}), /*#__PURE__*/React.createElement(FeatureCard, {
  icon: "flame",
  title: "Burn before reading",
  desc: "Delete a secret before the recipient views it."
}), /*#__PURE__*/React.createElement(FeatureCard, {
  icon: "shield-check",
  title: "Zero retained",
  desc: "After the view, the payload is wiped. We keep none of it."
}), /*#__PURE__*/React.createElement(FeatureCard, {
  icon: "code",
  title: "REST API",
  desc: "Create, retrieve, burn. Stable since 2014.",
  comp: true
})), /*#__PURE__*/React.createElement("div", {
  className: "ots-caps"
}, /*#__PURE__*/React.createElement("span", {
  className: "ots-caps-also"
}, "Also:"), /*#__PURE__*/React.createElement("span", {
  className: "ots-cap"
}, "Custom branding"), /*#__PURE__*/React.createElement("span", {
  className: "ots-cap"
}, "SSO"), /*#__PURE__*/React.createElement("span", {
  className: "ots-cap"
}, "Incoming secrets"), /*#__PURE__*/React.createElement("span", {
  className: "ots-cap"
}, "Access controls"))));
const HowItWorks = () => /*#__PURE__*/React.createElement("section", {
  className: "ots-section alt"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-container"
}, /*#__PURE__*/React.createElement("p", {
  className: "ots-section-label"
}, "How it works"), /*#__PURE__*/React.createElement("h2", {
  className: "ots-section-h2"
}, "Three verbs."), /*#__PURE__*/React.createElement("p", {
  className: "ots-section-sub"
}, "Nothing to configure, no workspace to create."), /*#__PURE__*/React.createElement("div", {
  className: "ots-steps"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-step"
}, /*#__PURE__*/React.createElement("span", {
  className: "ots-step-n"
}, "01"), /*#__PURE__*/React.createElement("h3", null, "Paste"), /*#__PURE__*/React.createElement("p", null, "Put your secret in the box. Add a passphrase if you need a second factor.")), /*#__PURE__*/React.createElement("div", {
  className: "ots-step"
}, /*#__PURE__*/React.createElement("span", {
  className: "ots-step-n"
}, "02"), /*#__PURE__*/React.createElement("h3", null, "Share"), /*#__PURE__*/React.createElement("p", null, "Send the one-time link \u2014 over Slack, email, whatever. Only the link grants access.")), /*#__PURE__*/React.createElement("div", {
  className: "ots-step"
}, /*#__PURE__*/React.createElement("span", {
  className: "ots-step-n"
}, "03"), /*#__PURE__*/React.createElement("h3", null, "Burn"), /*#__PURE__*/React.createElement("p", null, "After one view, the secret is gone. No copy, no log beyond the minimum necessary.")))));
const Cta = () => /*#__PURE__*/React.createElement("section", {
  className: "ots-cta"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-hero-glow c",
  "aria-hidden": "true"
}), /*#__PURE__*/React.createElement("div", {
  className: "ots-container narrow"
}, /*#__PURE__*/React.createElement("h2", {
  className: "ots-cta-h2"
}, /*#__PURE__*/React.createElement("span", null, "Stop pasting secrets"), /*#__PURE__*/React.createElement("span", {
  className: "ots-gradient-text"
}, "into Slack.")), /*#__PURE__*/React.createElement("p", {
  className: "ots-section-sub center"
}, "Free for individuals. Paid for teams that need branding, SSO, and retention controls."), /*#__PURE__*/React.createElement("div", {
  className: "ots-cta-btns"
}, /*#__PURE__*/React.createElement("button", {
  className: "ots-btn ots-btn-primary ots-btn-lg"
}, "Create a secret link"), /*#__PURE__*/React.createElement("button", {
  className: "ots-btn ots-btn-secondary ots-btn-lg"
}, "View pricing"))));
const Footer = () => /*#__PURE__*/React.createElement("footer", {
  className: "ots-footer"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-container"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-footer-grid"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-footer-brand"
}, /*#__PURE__*/React.createElement("img", {
  src: "../../assets/onetime-logo-v3-md.png",
  alt: "",
  width: "40",
  height: "40"
}), /*#__PURE__*/React.createElement("p", null, "Sharing sensitive information through self-destructing links. Since 2011.")), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("h4", null, "Product"), /*#__PURE__*/React.createElement("ul", null, /*#__PURE__*/React.createElement("li", null, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Pricing")), /*#__PURE__*/React.createElement("li", null, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "API")), /*#__PURE__*/React.createElement("li", null, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Status")))), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("h4", null, "Company"), /*#__PURE__*/React.createElement("ul", null, /*#__PURE__*/React.createElement("li", null, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "About")), /*#__PURE__*/React.createElement("li", null, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Blog")), /*#__PURE__*/React.createElement("li", null, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "GitHub")))), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("h4", null, "Regions"), /*#__PURE__*/React.createElement("ul", null, /*#__PURE__*/React.createElement("li", null, "eu.onetimesecret.com"), /*#__PURE__*/React.createElement("li", null, "us.onetimesecret.com"), /*#__PURE__*/React.createElement("li", null, "ca.onetimesecret.com"), /*#__PURE__*/React.createElement("li", null, "nz.onetimesecret.com")))), /*#__PURE__*/React.createElement("div", {
  className: "ots-footer-signoff"
}, /*#__PURE__*/React.createElement("span", null, "\xA9 2011\u20132026 Onetime Secret"), /*#__PURE__*/React.createElement("span", null, "Open source \xB7 ", /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Privacy"), " \xB7 ", /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Terms")))));
window.Features = Features;
window.HowItWorks = HowItWorks;
window.Cta = Cta;
window.Footer = Footer;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/marketing-site/Sections.jsx", error: String((e && e.message) || e) }); }

// ui_kits/marketing-site/app.jsx
try { (() => {
// Combined JSX — do not edit directly; edit MarketingNav.jsx / Hero.jsx / Sections.jsx

// ===== MarketingNav.jsx =====
// Nav component for marketing site
const MarketingNav = () => /*#__PURE__*/React.createElement("header", {
  className: "ots-nav"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-nav-inner"
}, /*#__PURE__*/React.createElement("a", {
  href: "#",
  className: "ots-brand"
}, /*#__PURE__*/React.createElement("img", {
  src: "../../assets/onetime-logo-v3-md.png",
  alt: "",
  width: "36",
  height: "36"
}), /*#__PURE__*/React.createElement("span", null, "Onetime Secret")), /*#__PURE__*/React.createElement("nav", {
  className: "ots-nav-links"
}, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Home"), /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "About"), /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Pricing"), /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Docs")), /*#__PURE__*/React.createElement("div", {
  className: "ots-nav-auth"
}, /*#__PURE__*/React.createElement("a", {
  href: "#",
  className: "ots-nav-signin"
}, "Sign in"), /*#__PURE__*/React.createElement("a", {
  href: "#",
  className: "ots-btn ots-btn-primary ots-btn-sm"
}, "Sign up \u2192"))));
window.MarketingNav = MarketingNav;

// ===== Hero.jsx =====
const {
  useState
} = React;
const Hero = () => {
  const [val, setVal] = useState("");
  return /*#__PURE__*/React.createElement("section", {
    className: "ots-hero",
    "aria-labelledby": "hero-heading"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-hero-glow a",
    "aria-hidden": "true"
  }), /*#__PURE__*/React.createElement("div", {
    className: "ots-hero-glow b",
    "aria-hidden": "true"
  }), /*#__PURE__*/React.createElement("div", {
    className: "ots-hero-inner"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-hero-badge"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-dot"
  }), "Now with regional data residency"), /*#__PURE__*/React.createElement("h1", {
    id: "hero-heading",
    className: "ots-hero-h1"
  }, /*#__PURE__*/React.createElement("span", null, "Keep sensitive info"), /*#__PURE__*/React.createElement("span", {
    className: "ots-gradient-text"
  }, " out of ", /*#__PURE__*/React.createElement("em", null, "your"), " inboxes.")), /*#__PURE__*/React.createElement("p", {
    className: "ots-hero-sub"
  }, "Share passwords, API keys, and private messages through links that self-destruct after one view."), /*#__PURE__*/React.createElement("div", {
    className: "ots-secret-form",
    role: "region",
    "aria-label": "Create a secret"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-region-row"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-region-label"
  }, "Store in"), /*#__PURE__*/React.createElement("button", {
    className: "ots-region-chip active"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-dot small"
  }), "\uD83C\uDDEA\uD83C\uDDFA EU"), /*#__PURE__*/React.createElement("button", {
    className: "ots-region-chip"
  }, "\uD83C\uDDFA\uD83C\uDDF8 US"), /*#__PURE__*/React.createElement("button", {
    className: "ots-region-chip"
  }, "\uD83C\uDDE8\uD83C\uDDE6 CA"), /*#__PURE__*/React.createElement("button", {
    className: "ots-region-chip"
  }, "\uD83C\uDDF3\uD83C\uDDFF NZ")), /*#__PURE__*/React.createElement("textarea", {
    className: "ots-secret-textarea",
    placeholder: "Paste the secret you'd like to share in the EU\u2026",
    value: val,
    onChange: e => setVal(e.target.value)
  }), /*#__PURE__*/React.createElement("div", {
    className: "ots-secret-foot"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-secret-meta"
  }, /*#__PURE__*/React.createElement("span", null, "Optional passphrase"), /*#__PURE__*/React.createElement("span", null, "\xB7"), /*#__PURE__*/React.createElement("span", null, "Expires in 7 days"), /*#__PURE__*/React.createElement("span", null, "\xB7"), /*#__PURE__*/React.createElement("span", null, "Burn before reading")), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-primary ots-btn-md"
  }, "Create a secret link"))), /*#__PURE__*/React.createElement("ul", {
    className: "ots-compliance",
    "aria-label": "Compliance"
  }, /*#__PURE__*/React.createElement("li", null, "SOC 2 Type II"), /*#__PURE__*/React.createElement("li", null, "GDPR-ready"), /*#__PURE__*/React.createElement("li", null, "HIPAA-adjacent workflows"), /*#__PURE__*/React.createElement("li", null, "Open source"), /*#__PURE__*/React.createElement("li", null, "Operating since 2011"))));
};
window.Hero = Hero;

// ===== Sections.jsx =====
const FeatureCard = ({
  icon,
  title,
  desc,
  span,
  comp
}) => /*#__PURE__*/React.createElement("div", {
  className: `ots-feat-card${span ? " span2" : ""}`
}, /*#__PURE__*/React.createElement("div", {
  className: `ots-feat-icon${comp ? " comp" : ""}`
}, /*#__PURE__*/React.createElement("i", {
  "data-lucide": icon,
  width: "22",
  height: "22"
})), /*#__PURE__*/React.createElement("h3", null, title), /*#__PURE__*/React.createElement("p", null, desc));
const Features = () => /*#__PURE__*/React.createElement("section", {
  className: "ots-section"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-container"
}, /*#__PURE__*/React.createElement("p", {
  className: "ots-section-label"
}, "What it does"), /*#__PURE__*/React.createElement("h2", {
  className: "ots-section-h2"
}, "Mechanism, not marketing."), /*#__PURE__*/React.createElement("p", {
  className: "ots-section-sub"
}, "Every feature exists to answer a specific security question. No abstractions."), /*#__PURE__*/React.createElement("div", {
  className: "ots-bento"
}, /*#__PURE__*/React.createElement(FeatureCard, {
  icon: "lock",
  title: "End-to-end encryption",
  desc: "AES-256 with bcrypt-hashed passphrases. Keys never leave the jurisdiction you chose.",
  span: true
}), /*#__PURE__*/React.createElement(FeatureCard, {
  icon: "clock",
  title: "Time-bound",
  desc: "Expire from minutes to 14 days."
}), /*#__PURE__*/React.createElement(FeatureCard, {
  icon: "flame",
  title: "Burn before reading",
  desc: "Delete a secret before the recipient views it."
}), /*#__PURE__*/React.createElement(FeatureCard, {
  icon: "shield-check",
  title: "Zero retained",
  desc: "After the view, the payload is wiped. We keep none of it."
}), /*#__PURE__*/React.createElement(FeatureCard, {
  icon: "code",
  title: "REST API",
  desc: "Create, retrieve, burn. Stable since 2014.",
  comp: true
})), /*#__PURE__*/React.createElement("div", {
  className: "ots-caps"
}, /*#__PURE__*/React.createElement("span", {
  className: "ots-caps-also"
}, "Also:"), /*#__PURE__*/React.createElement("span", {
  className: "ots-cap"
}, "Custom branding"), /*#__PURE__*/React.createElement("span", {
  className: "ots-cap"
}, "SSO"), /*#__PURE__*/React.createElement("span", {
  className: "ots-cap"
}, "Incoming secrets"), /*#__PURE__*/React.createElement("span", {
  className: "ots-cap"
}, "Access controls"))));
const HowItWorks = () => /*#__PURE__*/React.createElement("section", {
  className: "ots-section alt"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-container"
}, /*#__PURE__*/React.createElement("p", {
  className: "ots-section-label"
}, "How it works"), /*#__PURE__*/React.createElement("h2", {
  className: "ots-section-h2"
}, "Three verbs."), /*#__PURE__*/React.createElement("p", {
  className: "ots-section-sub"
}, "Nothing to configure, no workspace to create."), /*#__PURE__*/React.createElement("div", {
  className: "ots-steps"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-step"
}, /*#__PURE__*/React.createElement("span", {
  className: "ots-step-n"
}, "01"), /*#__PURE__*/React.createElement("h3", null, "Paste"), /*#__PURE__*/React.createElement("p", null, "Put your secret in the box. Add a passphrase if you need a second factor.")), /*#__PURE__*/React.createElement("div", {
  className: "ots-step"
}, /*#__PURE__*/React.createElement("span", {
  className: "ots-step-n"
}, "02"), /*#__PURE__*/React.createElement("h3", null, "Share"), /*#__PURE__*/React.createElement("p", null, "Send the one-time link \u2014 over Slack, email, whatever. Only the link grants access.")), /*#__PURE__*/React.createElement("div", {
  className: "ots-step"
}, /*#__PURE__*/React.createElement("span", {
  className: "ots-step-n"
}, "03"), /*#__PURE__*/React.createElement("h3", null, "Burn"), /*#__PURE__*/React.createElement("p", null, "After one view, the secret is gone. No copy, no log beyond the minimum necessary.")))));
const Cta = () => /*#__PURE__*/React.createElement("section", {
  className: "ots-cta"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-hero-glow c",
  "aria-hidden": "true"
}), /*#__PURE__*/React.createElement("div", {
  className: "ots-container narrow"
}, /*#__PURE__*/React.createElement("h2", {
  className: "ots-cta-h2"
}, /*#__PURE__*/React.createElement("span", null, "Stop pasting secrets"), /*#__PURE__*/React.createElement("span", {
  className: "ots-gradient-text"
}, "into Slack.")), /*#__PURE__*/React.createElement("p", {
  className: "ots-section-sub center"
}, "Free for individuals. Paid for teams that need branding, SSO, and retention controls."), /*#__PURE__*/React.createElement("div", {
  className: "ots-cta-btns"
}, /*#__PURE__*/React.createElement("button", {
  className: "ots-btn ots-btn-primary ots-btn-lg"
}, "Create a secret link"), /*#__PURE__*/React.createElement("button", {
  className: "ots-btn ots-btn-secondary ots-btn-lg"
}, "View pricing"))));
const Footer = () => /*#__PURE__*/React.createElement("footer", {
  className: "ots-footer"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-container"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-footer-grid"
}, /*#__PURE__*/React.createElement("div", {
  className: "ots-footer-brand"
}, /*#__PURE__*/React.createElement("img", {
  src: "../../assets/onetime-logo-v3-md.png",
  alt: "",
  width: "40",
  height: "40"
}), /*#__PURE__*/React.createElement("p", null, "Sharing sensitive information through self-destructing links. Since 2011.")), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("h4", null, "Product"), /*#__PURE__*/React.createElement("ul", null, /*#__PURE__*/React.createElement("li", null, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Pricing")), /*#__PURE__*/React.createElement("li", null, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "API")), /*#__PURE__*/React.createElement("li", null, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Status")))), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("h4", null, "Company"), /*#__PURE__*/React.createElement("ul", null, /*#__PURE__*/React.createElement("li", null, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "About")), /*#__PURE__*/React.createElement("li", null, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Blog")), /*#__PURE__*/React.createElement("li", null, /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "GitHub")))), /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("h4", null, "Regions"), /*#__PURE__*/React.createElement("ul", null, /*#__PURE__*/React.createElement("li", null, "eu.onetimesecret.com"), /*#__PURE__*/React.createElement("li", null, "us.onetimesecret.com"), /*#__PURE__*/React.createElement("li", null, "ca.onetimesecret.com"), /*#__PURE__*/React.createElement("li", null, "nz.onetimesecret.com")))), /*#__PURE__*/React.createElement("div", {
  className: "ots-footer-signoff"
}, /*#__PURE__*/React.createElement("span", null, "\xA9 2011\u20132026 Onetime Secret"), /*#__PURE__*/React.createElement("span", null, "Open source \xB7 ", /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Privacy"), " \xB7 ", /*#__PURE__*/React.createElement("a", {
  href: "#"
}, "Terms")))));
window.Features = Features;
window.HowItWorks = HowItWorks;
window.Cta = Cta;
window.Footer = Footer;

// ===== App mount =====
const App = () => /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement(MarketingNav, null), /*#__PURE__*/React.createElement(Hero, null), /*#__PURE__*/React.createElement(Features, null), /*#__PURE__*/React.createElement(HowItWorks, null), /*#__PURE__*/React.createElement(Cta, null), /*#__PURE__*/React.createElement(Footer, null));
ReactDOM.createRoot(document.getElementById("app")).render(/*#__PURE__*/React.createElement(App, null));
setTimeout(() => window.lucide && lucide.createIcons(), 200);
setTimeout(() => window.lucide && lucide.createIcons(), 800);
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/marketing-site/app.jsx", error: String((e && e.message) || e) }); }

// ui_kits/secret-app/Create.jsx
try { (() => {
const {
  useState,
  useRef,
  useEffect
} = React;
const AppShell = ({
  children,
  step = 1
}) => /*#__PURE__*/React.createElement("div", {
  className: "ots-app"
}, /*#__PURE__*/React.createElement("header", {
  className: "ots-app-nav"
}, /*#__PURE__*/React.createElement("a", {
  href: "#",
  className: "ots-brand"
}, /*#__PURE__*/React.createElement("img", {
  src: "../../assets/onetime-logo-v3-md.png",
  width: "32",
  height: "32",
  alt: ""
}), /*#__PURE__*/React.createElement("span", null, "Onetime Secret")), /*#__PURE__*/React.createElement("div", {
  className: "ots-app-nav-right"
}, /*#__PURE__*/React.createElement("span", {
  className: "ots-region-chip active small"
}, /*#__PURE__*/React.createElement("span", {
  className: "ots-dot small"
}), "\uD83C\uDDEA\uD83C\uDDFA EU"), /*#__PURE__*/React.createElement("button", {
  className: "ots-btn ots-btn-secondary ots-btn-sm"
}, "Dashboard"))), /*#__PURE__*/React.createElement("div", {
  className: "ots-app-crumb"
}, /*#__PURE__*/React.createElement("ol", null, /*#__PURE__*/React.createElement("li", {
  className: step >= 1 ? "done" : ""
}, /*#__PURE__*/React.createElement("span", null, "01"), "Compose"), /*#__PURE__*/React.createElement("li", {
  className: step >= 2 ? "done" : ""
}, /*#__PURE__*/React.createElement("span", null, "02"), "Share"), /*#__PURE__*/React.createElement("li", {
  className: step >= 3 ? "done" : ""
}, /*#__PURE__*/React.createElement("span", null, "03"), "Reveal"))), /*#__PURE__*/React.createElement("main", {
  className: "ots-app-main"
}, children));

// --- Popover primitive: click-to-open dropdown anchored to a chip ---
const Popover = ({
  open,
  onClose,
  children,
  align = "left"
}) => {
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return;
    const onDoc = e => {
      if (ref.current && !ref.current.contains(e.target)) onClose();
    };
    const onKey = e => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDoc);
      document.removeEventListener("keydown", onKey);
    };
  }, [open, onClose]);
  if (!open) return null;
  return /*#__PURE__*/React.createElement("div", {
    ref: ref,
    className: `ots-pop ots-pop-${align}`,
    role: "dialog"
  }, children);
};
const TTL_OPTIONS = [["5m", "5 minutes", "For code handoffs"], ["1h", "1 hour", "Default for team sharing"], ["1d", "1 day", "Overnight delivery"], ["7d", "7 days", "Default"], ["14d", "14 days", "Maximum"]];
const TTL_LABEL = Object.fromEntries(TTL_OPTIONS.map(([k, l]) => [k, l]));
const REGIONS = [["eu", "🇪🇺", "EU", "Frankfurt"], ["us", "🇺🇸", "US", "Virginia"], ["ca", "🇨🇦", "CA", "Montréal"], ["nz", "🇳🇿", "NZ", "Auckland"]];
const CreateForm = () => {
  const [secret, setSecret] = useState("");
  const [pass, setPass] = useState("");
  const [ttl, setTtl] = useState("7d");
  const [recipient, setRecipient] = useState("");
  const [burn, setBurn] = useState(false);
  const [region, setRegion] = useState("eu");
  const [open, setOpen] = useState(null); // 'ttl' | 'pass' | 'email' | 'region' | null

  const regionMeta = REGIONS.find(r => r[0] === region);
  const chip = (key, icon, label, active = false) => /*#__PURE__*/React.createElement("button", {
    className: `ots-chip${active ? " active" : ""}${open === key ? " open" : ""}`,
    onClick: e => {
      e.stopPropagation();
      setOpen(open === key ? null : key);
    },
    "aria-expanded": open === key,
    "aria-haspopup": "dialog",
    type: "button"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": icon,
    width: "13",
    height: "13"
  }), /*#__PURE__*/React.createElement("span", null, label), /*#__PURE__*/React.createElement("i", {
    "data-lucide": "chevron-down",
    width: "11",
    height: "11",
    className: "ots-chip-caret"
  }));
  return /*#__PURE__*/React.createElement("div", {
    className: "ots-stack lg"
  }, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("p", {
    className: "ots-eyebrow"
  }, "Step 01 \xB7 Compose"), /*#__PURE__*/React.createElement("h1", {
    className: "ots-app-h1"
  }, "Share something ", /*#__PURE__*/React.createElement("em", null, "once"), "."), /*#__PURE__*/React.createElement("p", {
    className: "ots-app-lead"
  }, "The recipient sees it exactly once. We keep nothing.")), /*#__PURE__*/React.createElement("section", {
    className: "ots-composer",
    "aria-label": "Compose secret"
  }, /*#__PURE__*/React.createElement("textarea", {
    className: "ots-composer-input",
    placeholder: "Paste a password, API key, recovery phrase, or private message\u2026",
    value: secret,
    onChange: e => setSecret(e.target.value),
    rows: 5
  }), /*#__PURE__*/React.createElement("div", {
    className: "ots-composer-tools"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-composer-tools-left"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-chip-wrap"
  }, chip("ttl", "clock", `Expires · ${TTL_LABEL[ttl]}`), /*#__PURE__*/React.createElement(Popover, {
    open: open === "ttl",
    onClose: () => setOpen(null)
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-pop-head"
  }, "Expire after"), /*#__PURE__*/React.createElement("div", {
    className: "ots-pop-list"
  }, TTL_OPTIONS.map(([k, label, hint]) => /*#__PURE__*/React.createElement("button", {
    key: k,
    className: `ots-pop-item${ttl === k ? " active" : ""}`,
    onClick: () => {
      setTtl(k);
      setOpen(null);
    }
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-pop-item-main"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-pop-item-label"
  }, label), /*#__PURE__*/React.createElement("span", {
    className: "ots-pop-item-hint"
  }, hint)), ttl === k && /*#__PURE__*/React.createElement("i", {
    "data-lucide": "check",
    width: "14",
    height: "14"
  })))))), /*#__PURE__*/React.createElement("div", {
    className: "ots-chip-wrap"
  }, chip("pass", "key", pass ? "Passphrase · set" : "Passphrase", !!pass), /*#__PURE__*/React.createElement(Popover, {
    open: open === "pass",
    onClose: () => setOpen(null)
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-pop-head"
  }, "Passphrase ", /*#__PURE__*/React.createElement("span", {
    className: "ots-optional"
  }, "(optional)")), /*#__PURE__*/React.createElement("p", {
    className: "ots-pop-desc"
  }, "A second factor. Share it through a different channel than the link."), /*#__PURE__*/React.createElement("input", {
    type: "password",
    autoFocus: true,
    className: "ots-input",
    placeholder: "Recipient must enter this to unlock",
    value: pass,
    onChange: e => setPass(e.target.value),
    onKeyDown: e => {
      if (e.key === "Enter") setOpen(null);
    }
  }), /*#__PURE__*/React.createElement("div", {
    className: "ots-pop-foot"
  }, pass && /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-ghost ots-btn-sm",
    onClick: () => setPass("")
  }, "Clear"), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-secondary ots-btn-sm",
    onClick: () => setOpen(null)
  }, "Done")))), /*#__PURE__*/React.createElement("div", {
    className: "ots-chip-wrap"
  }, chip("email", "mail", recipient ? "To · " + recipient : "Deliver to", !!recipient), /*#__PURE__*/React.createElement(Popover, {
    open: open === "email",
    onClose: () => setOpen(null)
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-pop-head"
  }, "Deliver to ", /*#__PURE__*/React.createElement("span", {
    className: "ots-optional"
  }, "(optional)")), /*#__PURE__*/React.createElement("p", {
    className: "ots-pop-desc"
  }, "We'll email the link \u2014 the email never contains the secret itself."), /*#__PURE__*/React.createElement("input", {
    type: "email",
    autoFocus: true,
    className: "ots-input",
    placeholder: "someone@company.com",
    value: recipient,
    onChange: e => setRecipient(e.target.value),
    onKeyDown: e => {
      if (e.key === "Enter") setOpen(null);
    }
  }), /*#__PURE__*/React.createElement("div", {
    className: "ots-pop-foot"
  }, recipient && /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-ghost ots-btn-sm",
    onClick: () => setRecipient("")
  }, "Clear"), /*#__PURE__*/React.createElement("div", {
    style: {
      flex: 1
    }
  }), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-secondary ots-btn-sm",
    onClick: () => setOpen(null)
  }, "Done")))), /*#__PURE__*/React.createElement("div", {
    className: "ots-chip-wrap"
  }, /*#__PURE__*/React.createElement("button", {
    className: `ots-chip${open === "region" ? " open" : ""}`,
    onClick: e => {
      e.stopPropagation();
      setOpen(open === "region" ? null : "region");
    },
    type: "button",
    "aria-expanded": open === "region"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-chip-flag"
  }, regionMeta[1]), /*#__PURE__*/React.createElement("span", null, regionMeta[2]), /*#__PURE__*/React.createElement("i", {
    "data-lucide": "chevron-down",
    width: "11",
    height: "11",
    className: "ots-chip-caret"
  })), /*#__PURE__*/React.createElement(Popover, {
    open: open === "region",
    onClose: () => setOpen(null)
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-pop-head"
  }, "Store in region"), /*#__PURE__*/React.createElement("p", {
    className: "ots-pop-desc"
  }, "Data stays in-region. Encryption keys never cross borders."), /*#__PURE__*/React.createElement("div", {
    className: "ots-pop-list"
  }, REGIONS.map(([k, flag, name, city]) => /*#__PURE__*/React.createElement("button", {
    key: k,
    className: `ots-pop-item${region === k ? " active" : ""}`,
    onClick: () => {
      setRegion(k);
      setOpen(null);
    }
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-pop-flag"
  }, flag), /*#__PURE__*/React.createElement("div", {
    className: "ots-pop-item-main"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-pop-item-label"
  }, name), /*#__PURE__*/React.createElement("span", {
    className: "ots-pop-item-hint"
  }, city)), region === k && /*#__PURE__*/React.createElement("i", {
    "data-lucide": "check",
    width: "14",
    height: "14"
  })))))), /*#__PURE__*/React.createElement("button", {
    className: `ots-chip ots-chip-toggle${burn ? " active" : ""}`,
    onClick: () => setBurn(!burn),
    "aria-pressed": burn,
    type: "button",
    title: "Lets you destroy the secret before it's viewed"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "flame",
    width: "13",
    height: "13"
  }), /*#__PURE__*/React.createElement("span", null, "Burn-before-read"), /*#__PURE__*/React.createElement("span", {
    className: `ots-mini-toggle${burn ? " on" : ""}`
  }, /*#__PURE__*/React.createElement("span", null)))), /*#__PURE__*/React.createElement("div", {
    className: "ots-composer-tools-right"
  }, /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-primary ots-btn-md ots-composer-submit",
    disabled: !secret,
    "aria-label": "Create secret link"
  }, /*#__PURE__*/React.createElement("span", null, "Create link"), /*#__PURE__*/React.createElement("i", {
    "data-lucide": "arrow-right",
    width: "14",
    height: "14"
  })))), /*#__PURE__*/React.createElement("div", {
    className: "ots-composer-status"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-status-left"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "lock",
    width: "11",
    height: "11"
  }), "Encrypted client-side \xB7 AES-256"), /*#__PURE__*/React.createElement("span", {
    className: "ots-status-right"
  }, secret.length.toLocaleString(), " / 100,000"))), /*#__PURE__*/React.createElement("p", {
    className: "ots-tip"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "info",
    width: "13",
    height: "13"
  }), "Tip: press ", /*#__PURE__*/React.createElement("kbd", null, "\u2318"), /*#__PURE__*/React.createElement("kbd", null, "Enter"), " to create. Secrets are never logged; only a salted hash of the link is retained for lookup."));
};
window.AppShell = AppShell;
window.CreateForm = CreateForm;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/secret-app/Create.jsx", error: String((e && e.message) || e) }); }

// ui_kits/secret-app/Reveal.jsx
try { (() => {
const {
  useState: useRevealState
} = React;
const RevealGate = ({
  onReveal
}) => {
  const [pass, setPass] = useRevealState("");
  return /*#__PURE__*/React.createElement("div", {
    className: "ots-stack lg"
  }, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("p", {
    className: "ots-eyebrow"
  }, "Step 03 \xB7 Reveal"), /*#__PURE__*/React.createElement("h1", {
    className: "ots-app-h1"
  }, "Someone sent you ", /*#__PURE__*/React.createElement("em", null, "a secret.")), /*#__PURE__*/React.createElement("p", {
    className: "ots-app-lead"
  }, "You'll be able to read it ", /*#__PURE__*/React.createElement("strong", null, "once"), ". Make sure you're in a safe place.")), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel focal"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-reveal-meta"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-region-chip active small"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-dot small"
  }), "\uD83C\uDDEA\uD83C\uDDFA Stored in EU"), /*#__PURE__*/React.createElement("span", {
    className: "ots-help inline"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "clock",
    width: "13",
    height: "13"
  }), " Expires in 6d 14h")), /*#__PURE__*/React.createElement("div", {
    className: "ots-reveal-lock"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "lock",
    width: "28",
    height: "28"
  })), /*#__PURE__*/React.createElement("label", {
    className: "ots-label",
    htmlFor: "unlock"
  }, "Passphrase"), /*#__PURE__*/React.createElement("input", {
    id: "unlock",
    type: "password",
    className: "ots-input large",
    placeholder: "Enter the passphrase you were sent",
    value: pass,
    onChange: e => setPass(e.target.value)
  }), /*#__PURE__*/React.createElement("div", {
    className: "ots-reveal-row"
  }, /*#__PURE__*/React.createElement("p", {
    className: "ots-help"
  }, "Once revealed, the secret is permanently destroyed."), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-primary ots-btn-lg",
    onClick: onReveal
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "eye",
    width: "14",
    height: "14"
  }), " Reveal secret"))), /*#__PURE__*/React.createElement("div", {
    className: "ots-warnings"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-warning"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "shield-alert",
    width: "16",
    height: "16"
  }), /*#__PURE__*/React.createElement("span", null, "Not expecting this? ", /*#__PURE__*/React.createElement("a", {
    href: "#"
  }, "Report it"), " and don't reveal."))));
};
const RevealResult = () => {
  const payload = "sk_live_51M8xP2Lk9nQr7sV4yW6tJ3bF8eD1cA5zY0uH2iN6oT9pX7mQ4rS3vB8wK1lE5hG9dC2";
  const [copied, setCopied] = useRevealState(false);
  return /*#__PURE__*/React.createElement("div", {
    className: "ots-stack lg"
  }, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("div", {
    className: "ots-success-badge warn"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "flame",
    width: "14",
    height: "14"
  }), " Burned after reading"), /*#__PURE__*/React.createElement("h1", {
    className: "ots-app-h1"
  }, "Here it is. ", /*#__PURE__*/React.createElement("em", null, "Don't lose it.")), /*#__PURE__*/React.createElement("p", {
    className: "ots-app-lead"
  }, "This is the only time you'll see it. Copy it somewhere safe now.")), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel focal"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-payload-head"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-label inline"
  }, "Secret"), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-secondary ots-btn-sm",
    onClick: () => {
      navigator.clipboard?.writeText(payload);
      setCopied(true);
      setTimeout(() => setCopied(false), 1400);
    }
  }, copied ? /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "check",
    width: "13",
    height: "13"
  }), " Copied") : /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "copy",
    width: "13",
    height: "13"
  }), " Copy"))), /*#__PURE__*/React.createElement("pre", {
    className: "ots-payload"
  }, payload), /*#__PURE__*/React.createElement("p", {
    className: "ots-help"
  }, "This secret has been wiped from our servers. Reloading this page will show a 404.")), /*#__PURE__*/React.createElement("div", {
    className: "ots-create-foot"
  }, /*#__PURE__*/React.createElement("p", {
    className: "ots-help"
  }, "Need to send one back? ", /*#__PURE__*/React.createElement("a", {
    className: "ots-accent-link",
    href: "#"
  }, "Create a reply.")), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-primary ots-btn-md"
  }, "Create my own secret \u2192")));
};
window.RevealGate = RevealGate;
window.RevealResult = RevealResult;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/secret-app/Reveal.jsx", error: String((e && e.message) || e) }); }

// ui_kits/secret-app/Share.jsx
try { (() => {
const ShareSuccess = () => {
  const url = "https://eu.onetimesecret.com/secret/a3f7x2k9-zq1p-4m8n-b6v5-d2w8t4r1n9e6";
  const [copied, setCopied] = React.useState(false);
  const copy = () => {
    setCopied(true);
    setTimeout(() => setCopied(false), 1400);
  };
  return /*#__PURE__*/React.createElement("div", {
    className: "ots-stack lg"
  }, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("div", {
    className: "ots-success-badge"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "check",
    width: "14",
    height: "14"
  }), " Secret created"), /*#__PURE__*/React.createElement("h1", {
    className: "ots-app-h1"
  }, "Send this link \u2014 ", /*#__PURE__*/React.createElement("em", null, "once.")), /*#__PURE__*/React.createElement("p", {
    className: "ots-app-lead"
  }, "It expires in 7 days or after the first view, whichever comes first.")), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel focal"
  }, /*#__PURE__*/React.createElement("label", {
    className: "ots-label"
  }, "One-time link"), /*#__PURE__*/React.createElement("div", {
    className: "ots-link-row"
  }, /*#__PURE__*/React.createElement("code", {
    className: "ots-link"
  }, url), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-primary ots-btn-md",
    onClick: copy
  }, copied ? /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "check",
    width: "14",
    height: "14"
  }), " Copied") : /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "copy",
    width: "14",
    height: "14"
  }), " Copy link"))), /*#__PURE__*/React.createElement("div", {
    className: "ots-link-meta"
  }, /*#__PURE__*/React.createElement("span", null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "clock",
    width: "13",
    height: "13"
  }), " Expires in 7d"), /*#__PURE__*/React.createElement("span", null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "eye",
    width: "13",
    height: "13"
  }), " 1 of 1 views remaining"), /*#__PURE__*/React.createElement("span", null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "globe",
    width: "13",
    height: "13"
  }), " eu.onetimesecret.com"))), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel"
  }, /*#__PURE__*/React.createElement("h3", {
    className: "ots-panel-h"
  }, "Passphrase required"), /*#__PURE__*/React.createElement("p", {
    className: "ots-help"
  }, "Share the passphrase through a different channel. A good rule: link via email, passphrase via Signal."), /*#__PURE__*/React.createElement("div", {
    className: "ots-code-display"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-label inline"
  }, "Passphrase"), /*#__PURE__*/React.createElement("code", null, "thunder-glacier-mint-42"), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-secondary ots-btn-sm"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "copy",
    width: "13",
    height: "13"
  }), " Copy"))), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel danger"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-danger-row"
  }, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("h3", {
    className: "ots-panel-h no-mb"
  }, "Change of plans?"), /*#__PURE__*/React.createElement("p", {
    className: "ots-help"
  }, "Burn the secret now. This is permanent.")), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-danger ots-btn-md"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "flame",
    width: "14",
    height: "14"
  }), " Burn before reading"))), /*#__PURE__*/React.createElement("div", {
    className: "ots-create-foot"
  }, /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-ghost ots-btn-md"
  }, "\u2190 Create another"), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-secondary ots-btn-md"
  }, "View in dashboard")));
};
window.ShareSuccess = ShareSuccess;
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/secret-app/Share.jsx", error: String((e && e.message) || e) }); }

// ui_kits/secret-app/app.jsx
try { (() => {
// Combined JSX — do not edit directly; edit Create.jsx / Share.jsx / Reveal.jsx

// ===== Create.jsx =====
const {
  useState
} = React;
const AppShell = ({
  children,
  step = 1
}) => /*#__PURE__*/React.createElement("div", {
  className: "ots-app"
}, /*#__PURE__*/React.createElement("header", {
  className: "ots-app-nav"
}, /*#__PURE__*/React.createElement("a", {
  href: "#",
  className: "ots-brand"
}, /*#__PURE__*/React.createElement("img", {
  src: "../../assets/onetime-logo-v3-md.png",
  width: "32",
  height: "32",
  alt: ""
}), /*#__PURE__*/React.createElement("span", null, "Onetime Secret")), /*#__PURE__*/React.createElement("div", {
  className: "ots-app-nav-right"
}, /*#__PURE__*/React.createElement("span", {
  className: "ots-region-chip active small"
}, /*#__PURE__*/React.createElement("span", {
  className: "ots-dot small"
}), "\uD83C\uDDEA\uD83C\uDDFA EU"), /*#__PURE__*/React.createElement("button", {
  className: "ots-btn ots-btn-secondary ots-btn-sm"
}, "Dashboard"))), /*#__PURE__*/React.createElement("div", {
  className: "ots-app-crumb"
}, /*#__PURE__*/React.createElement("ol", null, /*#__PURE__*/React.createElement("li", {
  className: step >= 1 ? "done" : ""
}, /*#__PURE__*/React.createElement("span", null, "01"), "Compose"), /*#__PURE__*/React.createElement("li", {
  className: step >= 2 ? "done" : ""
}, /*#__PURE__*/React.createElement("span", null, "02"), "Share"), /*#__PURE__*/React.createElement("li", {
  className: step >= 3 ? "done" : ""
}, /*#__PURE__*/React.createElement("span", null, "03"), "Reveal"))), /*#__PURE__*/React.createElement("main", {
  className: "ots-app-main"
}, children));
const CreateForm = () => {
  const [secret, setSecret] = useState("");
  const [pass, setPass] = useState("");
  const [ttl, setTtl] = useState("7d");
  const [recipient, setRecipient] = useState("");
  const [burn, setBurn] = useState(false);
  return /*#__PURE__*/React.createElement("div", {
    className: "ots-stack lg"
  }, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("p", {
    className: "ots-eyebrow"
  }, "Step 01 \xB7 Compose"), /*#__PURE__*/React.createElement("h1", {
    className: "ots-app-h1"
  }, "Share something ", /*#__PURE__*/React.createElement("em", null, "once"), "."), /*#__PURE__*/React.createElement("p", {
    className: "ots-app-lead"
  }, "The recipient sees it exactly once. We keep nothing.")), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel focal"
  }, /*#__PURE__*/React.createElement("label", {
    className: "ots-label",
    htmlFor: "secret"
  }, "Your secret"), /*#__PURE__*/React.createElement("textarea", {
    id: "secret",
    className: "ots-secret-textarea large",
    placeholder: "Password, API key, recovery phrase, anything sensitive\u2026",
    value: secret,
    onChange: e => setSecret(e.target.value)
  }), /*#__PURE__*/React.createElement("div", {
    className: "ots-charcount"
  }, /*#__PURE__*/React.createElement("span", null, secret.length.toLocaleString(), " / 100,000"), /*#__PURE__*/React.createElement("span", {
    className: "ots-encrypted"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "lock",
    width: "12",
    height: "12"
  }), "Encrypted client-side"))), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel"
  }, /*#__PURE__*/React.createElement("h3", {
    className: "ots-panel-h"
  }, "Security"), /*#__PURE__*/React.createElement("div", {
    className: "ots-field"
  }, /*#__PURE__*/React.createElement("label", {
    className: "ots-label",
    htmlFor: "pass"
  }, "Passphrase ", /*#__PURE__*/React.createElement("span", {
    className: "ots-optional"
  }, "(optional)")), /*#__PURE__*/React.createElement("input", {
    id: "pass",
    type: "password",
    className: "ots-input",
    placeholder: "Recipient must know this to unlock",
    value: pass,
    onChange: e => setPass(e.target.value)
  }), /*#__PURE__*/React.createElement("p", {
    className: "ots-help"
  }, "A second factor. Share it through a different channel than the link.")), /*#__PURE__*/React.createElement("div", {
    className: "ots-row"
  }, /*#__PURE__*/React.createElement("label", {
    className: "ots-toggle"
  }, /*#__PURE__*/React.createElement("input", {
    type: "checkbox",
    checked: burn,
    onChange: e => setBurn(e.target.checked)
  }), /*#__PURE__*/React.createElement("span", {
    className: "ots-toggle-track"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-toggle-thumb"
  })), /*#__PURE__*/React.createElement("span", {
    className: "ots-toggle-label"
  }, "Burn before reading")), /*#__PURE__*/React.createElement("span", {
    className: "ots-help inline"
  }, "Delete it yourself if plans change."))), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel"
  }, /*#__PURE__*/React.createElement("h3", {
    className: "ots-panel-h"
  }, "Expiration"), /*#__PURE__*/React.createElement("div", {
    className: "ots-segment",
    role: "radiogroup",
    "aria-label": "Expires after"
  }, [["5m", "5 min"], ["1h", "1 hour"], ["1d", "1 day"], ["7d", "7 days"], ["14d", "14 days"]].map(([k, l]) => /*#__PURE__*/React.createElement("button", {
    key: k,
    role: "radio",
    "aria-checked": ttl === k,
    className: `ots-segment-btn${ttl === k ? " active" : ""}`,
    onClick: () => setTtl(k)
  }, l)))), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel"
  }, /*#__PURE__*/React.createElement("h3", {
    className: "ots-panel-h"
  }, "Deliver to ", /*#__PURE__*/React.createElement("span", {
    className: "ots-optional"
  }, "(optional)")), /*#__PURE__*/React.createElement("input", {
    type: "email",
    className: "ots-input",
    placeholder: "someone@company.com",
    value: recipient,
    onChange: e => setRecipient(e.target.value)
  }), /*#__PURE__*/React.createElement("p", {
    className: "ots-help"
  }, "We'll email them the link. The email does not contain the secret.")), /*#__PURE__*/React.createElement("div", {
    className: "ots-create-foot"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-trust-strip"
  }, /*#__PURE__*/React.createElement("span", null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "shield-check",
    width: "13",
    height: "13"
  }), " AES-256"), /*#__PURE__*/React.createElement("span", null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "globe",
    width: "13",
    height: "13"
  }), " EU residency"), /*#__PURE__*/React.createElement("span", null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "flame",
    width: "13",
    height: "13"
  }), " Zero retained")), /*#__PURE__*/React.createElement("div", {
    className: "ots-create-btns"
  }, /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-ghost ots-btn-md"
  }, "Cancel"), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-primary ots-btn-lg"
  }, "Create a secret link \u2192"))));
};
window.AppShell = AppShell;
window.CreateForm = CreateForm;

// ===== Share.jsx =====
const ShareSuccess = () => {
  const url = "https://eu.onetimesecret.com/secret/a3f7x2k9-zq1p-4m8n-b6v5-d2w8t4r1n9e6";
  const [copied, setCopied] = React.useState(false);
  const copy = () => {
    setCopied(true);
    setTimeout(() => setCopied(false), 1400);
  };
  return /*#__PURE__*/React.createElement("div", {
    className: "ots-stack lg"
  }, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("div", {
    className: "ots-success-badge"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "check",
    width: "14",
    height: "14"
  }), " Secret created"), /*#__PURE__*/React.createElement("h1", {
    className: "ots-app-h1"
  }, "Send this link \u2014 ", /*#__PURE__*/React.createElement("em", null, "once.")), /*#__PURE__*/React.createElement("p", {
    className: "ots-app-lead"
  }, "It expires in 7 days or after the first view, whichever comes first.")), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel focal"
  }, /*#__PURE__*/React.createElement("label", {
    className: "ots-label"
  }, "One-time link"), /*#__PURE__*/React.createElement("div", {
    className: "ots-link-row"
  }, /*#__PURE__*/React.createElement("code", {
    className: "ots-link"
  }, url), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-primary ots-btn-md",
    onClick: copy
  }, copied ? /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "check",
    width: "14",
    height: "14"
  }), " Copied") : /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "copy",
    width: "14",
    height: "14"
  }), " Copy link"))), /*#__PURE__*/React.createElement("div", {
    className: "ots-link-meta"
  }, /*#__PURE__*/React.createElement("span", null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "clock",
    width: "13",
    height: "13"
  }), " Expires in 7d"), /*#__PURE__*/React.createElement("span", null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "eye",
    width: "13",
    height: "13"
  }), " 1 of 1 views remaining"), /*#__PURE__*/React.createElement("span", null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "globe",
    width: "13",
    height: "13"
  }), " eu.onetimesecret.com"))), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel"
  }, /*#__PURE__*/React.createElement("h3", {
    className: "ots-panel-h"
  }, "Passphrase required"), /*#__PURE__*/React.createElement("p", {
    className: "ots-help"
  }, "Share the passphrase through a different channel. A good rule: link via email, passphrase via Signal."), /*#__PURE__*/React.createElement("div", {
    className: "ots-code-display"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-label inline"
  }, "Passphrase"), /*#__PURE__*/React.createElement("code", null, "thunder-glacier-mint-42"), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-secondary ots-btn-sm"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "copy",
    width: "13",
    height: "13"
  }), " Copy"))), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel danger"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-danger-row"
  }, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("h3", {
    className: "ots-panel-h no-mb"
  }, "Change of plans?"), /*#__PURE__*/React.createElement("p", {
    className: "ots-help"
  }, "Burn the secret now. This is permanent.")), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-danger ots-btn-md"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "flame",
    width: "14",
    height: "14"
  }), " Burn before reading"))), /*#__PURE__*/React.createElement("div", {
    className: "ots-create-foot"
  }, /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-ghost ots-btn-md"
  }, "\u2190 Create another"), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-secondary ots-btn-md"
  }, "View in dashboard")));
};
window.ShareSuccess = ShareSuccess;

// ===== Reveal.jsx =====
const {
  useState: useRevealState
} = React;
const RevealGate = ({
  onReveal
}) => {
  const [pass, setPass] = useRevealState("");
  return /*#__PURE__*/React.createElement("div", {
    className: "ots-stack lg"
  }, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("p", {
    className: "ots-eyebrow"
  }, "Step 03 \xB7 Reveal"), /*#__PURE__*/React.createElement("h1", {
    className: "ots-app-h1"
  }, "Someone sent you ", /*#__PURE__*/React.createElement("em", null, "a secret.")), /*#__PURE__*/React.createElement("p", {
    className: "ots-app-lead"
  }, "You'll be able to read it ", /*#__PURE__*/React.createElement("strong", null, "once"), ". Make sure you're in a safe place.")), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel focal"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-reveal-meta"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-region-chip active small"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-dot small"
  }), "\uD83C\uDDEA\uD83C\uDDFA Stored in EU"), /*#__PURE__*/React.createElement("span", {
    className: "ots-help inline"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "clock",
    width: "13",
    height: "13"
  }), " Expires in 6d 14h")), /*#__PURE__*/React.createElement("div", {
    className: "ots-reveal-lock"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "lock",
    width: "28",
    height: "28"
  })), /*#__PURE__*/React.createElement("label", {
    className: "ots-label",
    htmlFor: "unlock"
  }, "Passphrase"), /*#__PURE__*/React.createElement("input", {
    id: "unlock",
    type: "password",
    className: "ots-input large",
    placeholder: "Enter the passphrase you were sent",
    value: pass,
    onChange: e => setPass(e.target.value)
  }), /*#__PURE__*/React.createElement("div", {
    className: "ots-reveal-row"
  }, /*#__PURE__*/React.createElement("p", {
    className: "ots-help"
  }, "Once revealed, the secret is permanently destroyed."), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-primary ots-btn-lg",
    onClick: onReveal
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "eye",
    width: "14",
    height: "14"
  }), " Reveal secret"))), /*#__PURE__*/React.createElement("div", {
    className: "ots-warnings"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-warning"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "shield-alert",
    width: "16",
    height: "16"
  }), /*#__PURE__*/React.createElement("span", null, "Not expecting this? ", /*#__PURE__*/React.createElement("a", {
    href: "#"
  }, "Report it"), " and don't reveal."))));
};
const RevealResult = () => {
  const payload = "sk_live_51M8xP2Lk9nQr7sV4yW6tJ3bF8eD1cA5zY0uH2iN6oT9pX7mQ4rS3vB8wK1lE5hG9dC2";
  const [copied, setCopied] = useRevealState(false);
  return /*#__PURE__*/React.createElement("div", {
    className: "ots-stack lg"
  }, /*#__PURE__*/React.createElement("div", null, /*#__PURE__*/React.createElement("div", {
    className: "ots-success-badge warn"
  }, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "flame",
    width: "14",
    height: "14"
  }), " Burned after reading"), /*#__PURE__*/React.createElement("h1", {
    className: "ots-app-h1"
  }, "Here it is. ", /*#__PURE__*/React.createElement("em", null, "Don't lose it.")), /*#__PURE__*/React.createElement("p", {
    className: "ots-app-lead"
  }, "This is the only time you'll see it. Copy it somewhere safe now.")), /*#__PURE__*/React.createElement("section", {
    className: "ots-panel focal"
  }, /*#__PURE__*/React.createElement("div", {
    className: "ots-payload-head"
  }, /*#__PURE__*/React.createElement("span", {
    className: "ots-label inline"
  }, "Secret"), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-secondary ots-btn-sm",
    onClick: () => {
      navigator.clipboard?.writeText(payload);
      setCopied(true);
      setTimeout(() => setCopied(false), 1400);
    }
  }, copied ? /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "check",
    width: "13",
    height: "13"
  }), " Copied") : /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("i", {
    "data-lucide": "copy",
    width: "13",
    height: "13"
  }), " Copy"))), /*#__PURE__*/React.createElement("pre", {
    className: "ots-payload"
  }, payload), /*#__PURE__*/React.createElement("p", {
    className: "ots-help"
  }, "This secret has been wiped from our servers. Reloading this page will show a 404.")), /*#__PURE__*/React.createElement("div", {
    className: "ots-create-foot"
  }, /*#__PURE__*/React.createElement("p", {
    className: "ots-help"
  }, "Need to send one back? ", /*#__PURE__*/React.createElement("a", {
    className: "ots-accent-link",
    href: "#"
  }, "Create a reply.")), /*#__PURE__*/React.createElement("button", {
    className: "ots-btn ots-btn-primary ots-btn-md"
  }, "Create my own secret \u2192")));
};
window.RevealGate = RevealGate;
window.RevealResult = RevealResult;

// ===== App mount =====
(() => {
  const {
    useState
  } = React;
  const VIEWS = [{
    k: "create",
    label: "01 · Compose",
    step: 1,
    screen: "App · Compose"
  }, {
    k: "share",
    label: "02 · Share",
    step: 2,
    screen: "App · Share success"
  }, {
    k: "gate",
    label: "03 · Gate",
    step: 3,
    screen: "App · Reveal gate"
  }, {
    k: "read",
    label: "03 · Reveal",
    step: 3,
    screen: "App · Reveal payload"
  }];
  const App = () => {
    const [k, setK] = useState(() => localStorage.getItem("ots-app-view") || "create");
    const set = x => {
      setK(x);
      localStorage.setItem("ots-app-view", x);
    };
    const view = VIEWS.find(v => v.k === k) || VIEWS[0];
    React.useEffect(() => {
      setTimeout(() => window.lucide && lucide.createIcons(), 100);
      setTimeout(() => window.lucide && lucide.createIcons(), 400);
    }, [k]);
    let screen;
    if (k === "create") screen = /*#__PURE__*/React.createElement(CreateForm, null);else if (k === "share") screen = /*#__PURE__*/React.createElement(ShareSuccess, null);else if (k === "gate") screen = /*#__PURE__*/React.createElement(RevealGate, {
      onReveal: () => set("read")
    });else screen = /*#__PURE__*/React.createElement(RevealResult, null);
    return /*#__PURE__*/React.createElement(React.Fragment, null, /*#__PURE__*/React.createElement("div", {
      className: "ots-viewer"
    }, /*#__PURE__*/React.createElement("div", {
      className: "ots-viewer-inner"
    }, /*#__PURE__*/React.createElement("span", {
      className: "ots-viewer-label"
    }, "Flow viewer"), /*#__PURE__*/React.createElement("div", {
      className: "ots-segment",
      role: "radiogroup",
      "aria-label": "Screen"
    }, VIEWS.map(v => /*#__PURE__*/React.createElement("button", {
      key: v.k,
      className: `ots-segment-btn${k === v.k ? " active" : ""}`,
      onClick: () => set(v.k)
    }, v.label))))), /*#__PURE__*/React.createElement("div", {
      "data-screen-label": view.screen
    }, /*#__PURE__*/React.createElement(AppShell, {
      step: view.step
    }, screen)));
  };
  ReactDOM.createRoot(document.getElementById("app")).render(/*#__PURE__*/React.createElement(App, null));
})();
})(); } catch (e) { __ds_ns.__errors.push({ path: "ui_kits/secret-app/app.jsx", error: String((e && e.message) || e) }); }

})();
