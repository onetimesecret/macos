use super::*;
use companion_core::continuous::{ContinuousEdit, ContinuousPageEdit};
use companion_core::{FragmentSelection, ItemId};
use serde_json::{Value, json};

fn selection(value: &Value) -> Option<TextSelection> {
    let object = value.as_object()?;
    if object.len() != 2 {
        return None;
    }
    let location_u16 = parse_u32(object.get("location")?)?;
    let length_u16 = parse_u32(object.get("length")?)?;
    location_u16.checked_add(length_u16)?;
    Some(TextSelection {
        location_u16,
        length_u16,
    })
}

fn parse_edit(json: &str) -> Option<ContinuousEdit> {
    let value: Value = serde_json::from_str(json).ok()?;
    let root = value.as_object()?;
    if root.len() != 3 {
        return None;
    }
    let intent = edit_intent(parse_u32(root.get("intent")?)?)?;
    let positions = root.get("selection")?.as_object()?;
    if positions.len() != 2 {
        return None;
    }
    let selection = EditSelection {
        before: selection(positions.get("before")?)?,
        after: selection(positions.get("after")?)?,
    };
    let mut pages = Vec::new();
    for value in root.get("pages")?.as_array()? {
        let part = value.as_object()?;
        if part.len()
            != 3 + usize::from(part.contains_key("join_next"))
                + usize::from(part.contains_key("expected_version"))
        {
            return None;
        }
        let page_id = SheetId::from_raw(part.get("page_id")?.as_u64()?);
        let expected_uuid = ItemId::parse(part.get("expected_uuid")?.as_str()?)?;
        let ops = parse_ops(&part.get("ops")?.to_string())?;
        let join_next = match part.get("join_next") {
            None => None,
            Some(Value::Null) => Some(None),
            Some(value) => Some(Some(ItemId::parse(value.as_str()?)?)),
        };
        pages.push(ContinuousPageEdit {
            page_id,
            expected_uuid,
            expected_version: parse_expected_version(part.get("expected_version"))?,
            ops,
            join_next,
        });
    }
    Some(ContinuousEdit {
        pages,
        intent,
        selection,
    })
}

fn parse_expected_version(value: Option<&Value>) -> Option<Option<Vec<u8>>> {
    match value {
        None => Some(None),
        Some(value) => value
            .as_array()?
            .iter()
            .map(|value| u8::try_from(value.as_u64()?).ok())
            .collect::<Option<Vec<_>>>()
            .map(Some),
    }
}

#[derive(serde::Serialize)]
struct Snapshot<'a> {
    uuid: String,
    version: Vec<u8>,
    join_next: Option<String>,
    runs: content_json::DocumentRuns<'a>,
}

/// # Safety
/// The handle must reference a live `CompanionHandle`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_continuous_snapshot(
    handle: *mut CompanionHandle,
    page: u64,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let Some(snapshot) = guard.store.continuous_snapshot(SheetId::from_raw(page)) else {
        return ptr::null_mut();
    };
    to_c_json(&Snapshot {
        uuid: snapshot.page.uuid().to_string(),
        version: snapshot.version,
        join_next: snapshot.join_next.map(|id| id.to_string()),
        runs: content_json::DocumentRuns(snapshot.page),
    })
}

/// # Safety
/// Pointers must reference a live handle and NUL-terminated UTF-8 strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_continuous_apply(
    handle: *mut CompanionHandle,
    scope: *const c_char,
    json: *const c_char,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(scope) = (unsafe { cstr(scope) }) else {
        return false;
    };
    let Some(json) = (unsafe { cstr(json) }) else {
        return false;
    };
    let Some(edit) = parse_edit(json) else {
        return false;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.apply_continuous(scope, &edit)
}

/// # Safety
/// The pointer must reference a live handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_continuous_scope_for_step(
    handle: *mut CompanionHandle,
    page: u64,
    back: bool,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    guard
        .store
        .continuous_scope_for_step(SheetId::from_raw(page), back)
        .and_then(|scope| CString::new(scope).ok())
        .map_or(ptr::null_mut(), CString::into_raw)
}

/// # Safety
/// Pointers must reference a live handle and a NUL-terminated UTF-8 scope.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_continuous_can_step(
    handle: *mut CompanionHandle,
    scope: *const c_char,
    back: bool,
) -> bool {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some(scope) = (unsafe { cstr(scope) }) else {
        return false;
    };
    let Ok(guard) = handle.inner.lock() else {
        return false;
    };
    guard.store.can_step_continuous(scope, back)
}

/// # Safety
/// Pointers must reference a live handle and a NUL-terminated UTF-8 scope.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_continuous_step(
    handle: *mut CompanionHandle,
    scope: *const c_char,
    back: bool,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Some(scope) = (unsafe { cstr(scope) }) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    let Some(step) = guard.store.step_continuous(scope, back) else {
        return ptr::null_mut();
    };
    to_c_json(&json!({
        "selection": {"location": step.selection.location_u16, "length": step.selection.length_u16},
        "pages": step.pages.iter().map(|page| page.raw()).collect::<Vec<_>>()
    }))
}

/// # Safety
/// Pointers must reference a live handle and a NUL-terminated UTF-8 scope.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_continuous_action_name(
    handle: *mut CompanionHandle,
    scope: *const c_char,
    back: bool,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Some(scope) = (unsafe { cstr(scope) }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    guard
        .store
        .continuous_action_name(scope, back)
        .and_then(|name| CString::new(name).ok())
        .map_or(ptr::null_mut(), CString::into_raw)
}

/// # Safety
/// The handle must reference a live `CompanionHandle`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_sheet_join_next(
    handle: *mut CompanionHandle,
    page: u64,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    guard
        .store
        .continuous_join_next(SheetId::from_raw(page))
        .and_then(|id| CString::new(id.to_string()).ok())
        .map_or(ptr::null_mut(), CString::into_raw)
}

/// # Safety
/// Pointers must reference a live handle and a NUL-terminated UTF-8 range array.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_continuous_copy(
    handle: *mut CompanionHandle,
    json: *const c_char,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Some(json) = (unsafe { cstr(json) }) else {
        return ptr::null_mut();
    };
    let Some(ranges) = parse_fragments(json) else {
        return ptr::null_mut();
    };
    let Ok(guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    copy_outcome_json(guard.store.copy_fragments(&ranges))
}

fn parse_fragments(json: &str) -> Option<Vec<FragmentSelection>> {
    let value: Value = serde_json::from_str(json).ok()?;
    value
        .as_array()?
        .iter()
        .map(|value| {
            let part = value.as_object()?;
            if part.len() != 5 + usize::from(part.contains_key("expected_version")) {
                return None;
            }
            Some(FragmentSelection {
                page: SheetId::from_raw(part.get("page_id")?.as_u64()?),
                expected_uuid: ItemId::parse(part.get("expected_uuid")?.as_str()?)?,
                expected_version: parse_expected_version(part.get("expected_version"))?,
                at_u16: parse_u32(part.get("at")?)?,
                len_u16: parse_u32(part.get("len")?)?,
                separator_after: part.get("separator_after")?.as_bool()?,
            })
        })
        .collect()
}

/// # Safety
/// Pointers must reference a live handle and a NUL-terminated UTF-8 scope.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_continuous_finish_group(
    handle: *mut CompanionHandle,
    scope: *const c_char,
) {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return;
    };
    let Some(scope) = (unsafe { cstr(scope) }) else {
        return;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return;
    };
    guard.store.finish_continuous_group(scope);
}

/// # Safety
/// Pointers must reference a live handle and NUL-terminated UTF-8 strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_continuous_clear_history(
    handle: *mut CompanionHandle,
    scope: *const c_char,
) {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return;
    };
    let Some(scope) = (unsafe { cstr(scope) }) else {
        return;
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return;
    };
    guard.store.clear_continuous_history(scope);
}

/// # Safety
/// Pointers must reference a live handle and NUL-terminated UTF-8 strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_continuous_cut(
    handle: *mut CompanionHandle,
    scope: *const c_char,
    ranges_json: *const c_char,
    edit_json: *const c_char,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Some(scope) = (unsafe { cstr(scope) }) else {
        return ptr::null_mut();
    };
    let Some(ranges) = (unsafe { cstr(ranges_json) }).and_then(parse_fragments) else {
        return ptr::null_mut();
    };
    let Some(edit) = (unsafe { cstr(edit_json) }).and_then(parse_edit) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    copy_outcome_json(guard.store.cut_continuous(scope, &ranges, &edit))
}

/// # Safety
/// Strings and handle must be valid; envelope must be null or readable for `envelope_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_continuous_paste(
    handle: *mut CompanionHandle,
    scope: *const c_char,
    edit_json: *const c_char,
    target: u64,
    at_utf16: u32,
    envelope: *const u8,
    envelope_len: usize,
    plain: *const c_char,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Some(scope) = (unsafe { cstr(scope) }) else {
        return ptr::null_mut();
    };
    let Some(edit) = (unsafe { cstr(edit_json) }).and_then(parse_edit) else {
        return ptr::null_mut();
    };
    let bytes = if envelope.is_null() || envelope_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(envelope, envelope_len) }
    };
    let plain = unsafe { cstr(plain) };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    guard
        .store
        .paste_continuous(
            scope,
            &edit,
            SheetId::from_raw(target),
            at_utf16,
            bytes,
            plain,
        )
        .map_or(ptr::null_mut(), placed_json)
}

/// # Safety
/// Pointers must reference a live handle and NUL-terminated UTF-8 strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_continuous_place_active_cut(
    handle: *mut CompanionHandle,
    scope: *const c_char,
    edit_json: *const c_char,
    target: u64,
    at_utf16: u32,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Some(scope) = (unsafe { cstr(scope) }) else {
        return ptr::null_mut();
    };
    let Some(edit) = (unsafe { cstr(edit_json) }).and_then(parse_edit) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    guard
        .store
        .paste_active_cut_continuous(scope, &edit, SheetId::from_raw(target), at_utf16)
        .map_or(ptr::null_mut(), placed_json)
}

/// # Safety
/// Pointers must reference a live handle and NUL-terminated UTF-8 strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn companion_continuous_move(
    handle: *mut CompanionHandle,
    scope: *const c_char,
    ranges_json: *const c_char,
    edit_json: *const c_char,
    target: u64,
    at_utf16: u32,
    cloning: bool,
) -> *mut c_char {
    let Some(handle) = (unsafe { handle.as_ref() }) else {
        return ptr::null_mut();
    };
    let Some(scope) = (unsafe { cstr(scope) }) else {
        return ptr::null_mut();
    };
    let Some(ranges) = (unsafe { cstr(ranges_json) }).and_then(parse_fragments) else {
        return ptr::null_mut();
    };
    let Some(edit) = (unsafe { cstr(edit_json) }).and_then(parse_edit) else {
        return ptr::null_mut();
    };
    let Ok(mut guard) = handle.inner.lock() else {
        return ptr::null_mut();
    };
    guard
        .store
        .move_continuous(
            scope,
            &ranges,
            &edit,
            SheetId::from_raw(target),
            at_utf16,
            cloning,
        )
        .map_or(ptr::null_mut(), placed_json)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid() -> Value {
        json!({
            "pages": [{"page_id": 1, "expected_uuid": ItemId::random().to_string(),
                       "ops": [{"del": {"at": 0, "len": 2}}], "join_next": null}],
            "intent": 4,
            "selection": {"before": {"location": 0, "length": 2}, "after": {"location": 0, "length": 0}}
        })
    }

    #[test]
    fn wire_distinguishes_unchanged_boundary_from_restored_newline() {
        let mut value = valid();
        let edit = parse_edit(&value.to_string()).unwrap();
        assert_eq!(edit.pages[0].join_next, Some(None));
        value["pages"][0]
            .as_object_mut()
            .unwrap()
            .remove("join_next");
        assert_eq!(
            parse_edit(&value.to_string()).unwrap().pages[0].join_next,
            None
        );
        value["pages"][0]["join_next"] = json!(ItemId::random().to_string());
        assert!(
            parse_edit(&value.to_string()).unwrap().pages[0]
                .join_next
                .flatten()
                .is_some()
        );
    }

    #[test]
    fn wire_accepts_only_exact_byte_arrays_for_expected_versions() {
        let mut value = valid();
        value["pages"][0]["expected_version"] = json!([0, 127, 255]);
        assert_eq!(
            parse_edit(&value.to_string()).unwrap().pages[0].expected_version,
            Some(vec![0, 127, 255])
        );
        for version in [
            json!([256]),
            json!([-1]),
            json!([1.5]),
            Value::Null,
            json!("AA=="),
        ] {
            value["pages"][0]["expected_version"] = version;
            assert!(parse_edit(&value.to_string()).is_none());
        }
    }

    #[test]
    fn wire_refuses_unknown_fields_ranges_and_intents() {
        let mut value = valid();
        value["extra"] = json!(true);
        assert!(parse_edit(&value.to_string()).is_none());
        value = valid();
        value["intent"] = json!(99);
        assert!(parse_edit(&value.to_string()).is_none());
        value = valid();
        value["selection"]["before"] = json!({"location": u32::MAX, "length": 1});
        assert!(parse_edit(&value.to_string()).is_none());
        value = valid();
        value["pages"][0]["ops"][0]["del"]["at"] = json!(-1);
        assert!(parse_edit(&value.to_string()).is_none());
    }
}
