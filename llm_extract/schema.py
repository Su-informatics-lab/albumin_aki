"""Pydantic schema for albumin_aki cardiac-surgery endpoint extraction."""

from __future__ import annotations

from enum import Enum
from typing import Any, Optional, Type, Union, get_args, get_origin

from pydantic import BaseModel, ConfigDict, Field, field_validator


class Confidence(str, Enum):
    high = "high"
    medium = "medium"
    low = "low"


class ResternotomyReason(str, Enum):
    bleeding = "bleeding"
    tamponade = "tamponade"
    other = "other"
    none = "none"


class EndpointAssessment(BaseModel):
    """One binary postoperative endpoint with traceability for QC."""

    model_config = ConfigDict(extra="forbid")

    value: int = Field(
        description=(
            "0 if absent, negated, historical/pre-existing only, ruled out, "
            "expected routine postoperative care, or too ambiguous to count; "
            "1 if the postoperative complication occurred during this "
            "hospitalization."
        )
    )
    confidence: Confidence = Field(
        description=(
            "high if explicitly documented; medium if clearly supported by "
            "context; low if ambiguous."
        )
    )
    evidence: Optional[str] = Field(
        None,
        description=(
            "Short exact phrase from the note supporting a positive endpoint. "
            "Use null when value is 0 or no concise phrase is available."
        ),
    )

    @field_validator("value", mode="before")
    @classmethod
    def coerce_binary(cls, value: Any) -> int:
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, str):
            stripped = value.strip().lower()
            if stripped in {"true", "yes", "present"}:
                return 1
            if stripped in {"false", "no", "absent"}:
                return 0
        return value

    @field_validator("value")
    @classmethod
    def validate_binary(cls, value: int) -> int:
        if value not in (0, 1):
            raise ValueError("endpoint value must be 0 or 1")
        return value


class CardiacSurgeryEndpoints(BaseModel):
    """Postoperative complications after cardiac surgery."""

    model_config = ConfigDict(extra="forbid")

    return_to_or: EndpointAssessment = Field(
        description=(
            "Reoperation, resternotomy, re-exploration, or return to the "
            "operating room after the index cardiac surgery, especially for "
            "bleeding or tamponade. Exclude planned staged procedures."
        )
    )
    resternotomy_reason: ResternotomyReason = Field(
        description=(
            "Primary reason for resternotomy/return to OR: bleeding, "
            "tamponade, other, or none if return_to_or is 0."
        )
    )
    reintubation: EndpointAssessment = Field(
        description=(
            "Reintubation after initial extubation, failed extubation requiring "
            "reintubation, or unplanned return to invasive mechanical "
            "ventilation. Exclude routine immediate postoperative intubation."
        )
    )
    pneumonia_vap: EndpointAssessment = Field(
        description=(
            "New pneumonia, aspiration pneumonia, hospital-acquired pneumonia, "
            "or ventilator-associated pneumonia during this hospitalization. "
            "Exclude remote history, prophylaxis, and ruled-out pneumonia."
        )
    )
    sepsis: EndpointAssessment = Field(
        description=(
            "New sepsis or septic shock during this hospitalization. Exclude "
            "initial postoperative SIRS/inflammatory response unless the note "
            "diagnoses sepsis or septic shock."
        )
    )
    sternal_wound_inf: EndpointAssessment = Field(
        description=(
            "Sternal wound infection, mediastinitis, deep surgical site "
            "infection, purulent sternal drainage, or wound VAC for infection. "
            "Exclude clean/dry/intact wound statements."
        )
    )
    bloodstream_inf: EndpointAssessment = Field(
        description=(
            "Bloodstream infection, bacteremia, fungemia, positive blood "
            "culture with clinical infection, or line-associated bloodstream "
            "infection. Exclude contaminants or isolated culture follow-up "
            "without infection."
        )
    )
    cardiac_arrest: EndpointAssessment = Field(
        description=(
            "Cardiac arrest, code blue, pulseless event, CPR, ACLS, or ROSC "
            "during this hospitalization. Exclude purely intraoperative events "
            "unless also documented postoperatively."
        )
    )
    poaf: EndpointAssessment = Field(
        description=(
            "New-onset postoperative atrial fibrillation or flutter. Exclude "
            "chronic/pre-existing AF unless the note explicitly documents a "
            "new postoperative episode."
        )
    )
    acute_heart_failure: EndpointAssessment = Field(
        description=(
            "New or worsened heart failure, cardiogenic shock, low-output "
            "syndrome, or ventricular failure requiring inotropes or "
            "mechanical circulatory support. Exclude baseline CHF alone and "
            "routine brief postoperative pressor use."
        )
    )
    stroke: EndpointAssessment = Field(
        description=(
            "New stroke, CVA, TIA, or acute cerebrovascular event during this "
            "hospitalization. Exclude prior stroke history."
        )
    )
    delirium: EndpointAssessment = Field(
        description=(
            "New delirium, encephalopathy, acute confusion, altered mental "
            "status, CAM-positive delirium, or severe agitation during this "
            "hospitalization. Exclude baseline dementia alone."
        )
    )
    myocardial_injury: EndpointAssessment = Field(
        description=(
            "Perioperative myocardial infarction, NSTEMI/STEMI, myocardial "
            "injury, or significant troponin elevation documented in the note. "
            "Do not infer from labs that are not mentioned in the text."
        )
    )
    confidence: Confidence = Field(
        description=(
            "Overall confidence in the extraction across all endpoints: high, "
            "medium, or low."
        )
    )
    extraction_note: str = Field(
        "",
        description="Brief free-text note on ambiguities. Empty string if none.",
    )


ENDPOINTS = [
    "return_to_or",
    "reintubation",
    "pneumonia_vap",
    "sepsis",
    "sternal_wound_inf",
    "bloodstream_inf",
    "cardiac_arrest",
    "poaf",
    "acute_heart_failure",
    "stroke",
    "delirium",
    "myocardial_injury",
]

REQUIRED_OUTPUT_COLUMNS = [
    "hadm_id",
    "pid",
    *ENDPOINTS,
    "confidence",
]


def unwrap_optional(annotation: Any) -> tuple[Any, bool]:
    origin = get_origin(annotation)
    args = get_args(annotation)
    if origin is Union and type(None) in args:
        inner = [arg for arg in args if arg is not type(None)]
        if len(inner) == 1:
            return inner[0], True
    return annotation, False


def describe_field(name: str, info: Any, indent: int = 0) -> list[str]:
    prefix = "  " * indent
    lines: list[str] = []
    description = info.description or ""
    raw_annotation = info.annotation
    inner, is_optional = unwrap_optional(raw_annotation)
    optional_suffix = " (optional)" if is_optional else ""
    origin = get_origin(inner)

    if origin is list:
        args = get_args(inner)
        lines.append(f"{prefix}- {name}{optional_suffix}: {description}")
        if args and isinstance(args[0], type) and issubclass(args[0], BaseModel):
            for sub_name, sub_info in args[0].model_fields.items():
                lines.extend(describe_field(sub_name, sub_info, indent + 2))
        return lines

    if isinstance(inner, type) and issubclass(inner, Enum):
        allowed = [member.value for member in inner]
        lines.append(
            f"{prefix}- {name}{optional_suffix}: {description}. Allowed: {allowed}"
        )
        return lines

    if isinstance(inner, type) and issubclass(inner, BaseModel):
        lines.append(f"{prefix}- {name}{optional_suffix}: {description}")
        for sub_name, sub_info in inner.model_fields.items():
            lines.extend(describe_field(sub_name, sub_info, indent + 1))
        return lines

    lines.append(f"{prefix}- {name}{optional_suffix}: {description}")
    return lines


def build_format_instructions(
    model: Optional[Type[BaseModel]] = None,
) -> str:
    if model is None:
        model = CardiacSurgeryEndpoints

    lines = [
        "Respond with a single JSON object conforming to this schema:",
        "",
        f"Root model: {model.__name__}",
        "",
    ]
    for name, info in model.model_fields.items():
        lines.extend(describe_field(name, info, indent=0))
    lines.extend(
        [
            "",
            "For each endpoint, value must be 0 or 1.",
            "Use null for endpoint evidence when value is 0.",
            'Use resternotomy_reason="none" when return_to_or.value is 0.',
            "Do not invent information not present in the note.",
            "Output valid JSON only. No markdown fences. No commentary.",
        ]
    )
    return "\n".join(lines)
