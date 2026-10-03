FROM python:3.14-slim-bookworm as base
WORKDIR /app
COPY ./*.py /app/
COPY Pipfile Pipfile.lock /app/
RUN pip install pipenv && pipenv install --deploy --ignore-pipfile

# fresh image
FROM base
COPY /app /app --from=base
CMD ["pipenv", "run", "python", "main.py"]
