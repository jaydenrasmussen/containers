FROM python:3.19-slim-bookworm as base
COPY ./*.py /app/
COPY ./requirements.txt /app/
RUN pip install --upgrade pip
RUN pip install -r /app/requirements.txt
CMD ["python", "main.py"]
