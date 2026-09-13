import json

base_word = "apple " # 1 token
def generate_prompt(persona_id):
    # Roughly 2000 words
    filler = (f"This is some filler context for persona {persona_id}. " * 150)
    return f"You are Persona {persona_id}. " + filler

prompts = [{"id": i, "text": generate_prompt(i)} for i in range(1, 17)]
with open('tests/e2e/benchmark/prompts.json', 'w') as f:
    json.dump(prompts, f, indent=2)
