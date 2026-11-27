//! The window's own look: the pack's symbolic icons (a GResource built by
//! build.rs), the brand accent, and the status tints, as one CSS provider
//! that follows the light or dark appearance. Colours come from the pack's
//! `tokens.json`; everything not listed there is libadwaita's.

use std::sync::Once;

use gtk4 as gtk;
use gtk::{gdk, gio, glib};
use libadwaita as adw;

const STYLE: &str = include_str!("../resources/style.css");

/// The compiled `resources/` (the icons).
const RESOURCE: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/nice-dns.gresource"));

const LIGHT: &str = "
@define-color accent_bg_color #0A7A5C;
@define-color accent_color #0A6B51;
@define-color nd_ok_icon #0A7A5C;
@define-color nd_ok_tint #DDF3EA;
@define-color nd_ok_node_fill #F1FAF6;
@define-color nd_ok_node_border #8CCBB5;
@define-color nd_ok_pill_text #0A5C46;
@define-color nd_att_icon #8A4B00;
@define-color nd_att_text #6E3C00;
@define-color nd_att_tint #FFE7B0;
@define-color nd_att_node_fill #FFF6E0;
@define-color nd_att_node_border #C98A1A;
@define-color nd_down_icon #B3261E;
@define-color nd_down_text #8C1D18;
@define-color nd_down_tint #FCE9E7;
@define-color nd_down_node_fill #FDF1F0;
@define-color nd_down_node_border #D9807A;
@define-color nd_neutral_icon #5E6066;
@define-color nd_neutral_border #C9CBD1;
@define-color nd_inset #F3F3F5;
@define-color nd_stderr #8A5A00;
";

const DARK: &str = "
@define-color accent_bg_color #1E9C76;
@define-color accent_color #4FD6A8;
@define-color nd_ok_icon #4FD6A8;
@define-color nd_ok_tint rgba(79,214,168,0.16);
@define-color nd_ok_node_fill rgba(79,214,168,0.10);
@define-color nd_ok_node_border #2F8E72;
@define-color nd_ok_pill_text #4FD6A8;
@define-color nd_att_icon #FFC861;
@define-color nd_att_text #FFD98A;
@define-color nd_att_tint rgba(255,200,97,0.18);
@define-color nd_att_node_fill rgba(255,200,97,0.10);
@define-color nd_att_node_border #B98A2E;
@define-color nd_down_icon #FF8A80;
@define-color nd_down_text #FFB4AB;
@define-color nd_down_tint rgba(255,138,128,0.18);
@define-color nd_down_node_fill rgba(255,138,128,0.10);
@define-color nd_down_node_border #B5574F;
@define-color nd_neutral_icon #C9CBD1;
@define-color nd_neutral_border #6B6E76;
@define-color nd_inset #1B1C1E;
@define-color nd_stderr #D9B46A;
";

fn css(dark: bool) -> String {
    format!("{}{STYLE}", if dark { DARK } else { LIGHT })
}

/// Register the icons and the style, once; the style follows the system
/// appearance.
pub fn init() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let Some(display) = gdk::Display::default() else { return };
        match gio::Resource::from_data(&glib::Bytes::from_static(RESOURCE)) {
            Ok(res) => gio::resources_register(&res),
            Err(e) => eprintln!("nice-dns-gui: the bundled icons are unreadable: {e}"),
        }
        gtk::IconTheme::for_display(&display).add_resource_path("/org/nice_dns/Gui/icons");
        let manager = adw::StyleManager::default();
        let provider = gtk::CssProvider::new();
        provider.load_from_string(&css(manager.is_dark()));
        gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
        manager.connect_dark_notify(move |m| provider.load_from_string(&css(m.is_dark())));
    });
}
